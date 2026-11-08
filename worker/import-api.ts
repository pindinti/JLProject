import { validateImportSubmission } from "../domain/import-contract";
import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import type { Identity } from "./auth";
import type { WorkerEnvironment } from "./database";
import { createImportRepository, type ImportRepository } from "./import-repository";

const path = /^\/api\/workspaces\/([^/]+)\/imports$/;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const maxBytes = 256 * 1024;

export type ImportRepositoryFactory = (environment: WorkerEnvironment) => ImportRepository;
export function isImportRoute(pathname: string): boolean { return path.test(pathname); }

function response(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

async function readBoundedBody(request: Request): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > maxBytes) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

export async function handleImportRequest(
  request: Request,
  identity: Identity,
  memberships: MembershipRepository,
  environment: WorkerEnvironment,
  repositoryFactory: ImportRepositoryFactory = createImportRepository
): Promise<Response> {
  const match = new URL(request.url).pathname.match(path);
  if (!match) return response({ error: "Não encontrado." }, 404);
  if (!uuid.test(match[1])) return response({ error: "Identificador inválido." }, 400);
  const membership = await authorizeWorkspace(identity, match[1], "edit", memberships);
  if (!membership) return response({ error: "Acesso não autorizado." }, 403);
  if (request.method !== "POST") return response({ error: "Método não permitido." }, 405);
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json"))
    return response({ error: "Dados de importação inválidos." }, 400);
  const length = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(length) && length > maxBytes) return response({ error: "Importação muito grande." }, 413);
  let raw: string | null;
  try { raw = await readBoundedBody(request); }
  catch { return response({ error: "Dados de importação inválidos." }, 400); }
  if (raw === null) return response({ error: "Importação muito grande." }, 413);
  let payload: unknown;
  try { payload = JSON.parse(raw); } catch { return response({ error: "Dados de importação inválidos." }, 400); }
  if (!validateImportSubmission(payload)) return response({ error: "Dados de importação inválidos." }, 400);
  const result = await repositoryFactory(environment).import(membership.workspaceId, identity.subject, payload);
  if (result.status === "denied") return response({ error: "Acesso não autorizado." }, 403);
  if (result.status === "duplicate") return response({ code: "duplicate", error: "Esta planilha já foi importada." }, 409);
  if (result.status === "conflict") return response({ code: "conflict", error: "Esta tentativa de importação foi alterada." }, 409);
  if (result.status !== "created" && result.status !== "replayed")
    return response({ error: "Serviço indisponível." }, 503);
  if (!uuid.test(result.productId) || !uuid.test(result.revisionId) || result.revisionLabel !== "R00")
    return response({ error: "Serviço indisponível." }, 503);
  return response({ productId: result.productId, revisionId: result.revisionId,
    revisionLabel: result.revisionLabel, replayed: result.status === "replayed" },
  result.status === "created" ? 201 : 200);
}
