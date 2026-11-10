import { authorizeWorkspace, type MembershipRepository } from "./authorization";
import type { Identity } from "./auth";
import { createProductRepository, type ProductCloneMutation, type ProductInput, type ProductMutation, type ProductRepository } from "./products";
import type { WorkerEnvironment } from "./database";

const productPath = /^\/api\/workspaces\/([^/]+)\/products(?:\/([^/]+)(?:\/(archive|clone))?)?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type ProductRepositoryFactory = (environment: WorkerEnvironment) => ProductRepository;

function response(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
}

async function readBody(request: Request): Promise<Record<string, unknown> | null> {
  if (!request.headers.get("Content-Type")?.toLowerCase().startsWith("application/json")) return null;
  const body = await request.text();
  if (body.length > 4096) return null;
  try {
    const value: unknown = JSON.parse(body);
    return value && typeof value === "object" && !Array.isArray(value)
      ? value as Record<string, unknown> : null;
  } catch { return null; }
}

function parseProductInput(body: Record<string, unknown>, editing: boolean):
  { input: ProductInput; version?: number } | null {
  const keys = Object.keys(body);
  if (!keys.includes("name") || keys.some((key) => !["name", "description", ...(editing ? ["version"] : [])].includes(key))) return null;
  if (typeof body["name"] !== "string") return null;
  const name = body["name"].trim();
  if (name.length < 1 || name.length > 200) return null;
  const descriptionValue = body["description"] ?? null;
  if (descriptionValue !== null && typeof descriptionValue !== "string") return null;
  const description = typeof descriptionValue === "string" && descriptionValue.trim()
    ? descriptionValue.trim() : null;
  if (description !== null && description.length > 2000) return null;
  if (editing && (!Number.isSafeInteger(body["version"]) || Number(body["version"]) < 1)) return null;
  return { input: { name, description }, ...(editing ? { version: Number(body["version"]) } : {}) };
}

function parseArchiveBody(body: Record<string, unknown>): number | null {
  return Object.keys(body).length === 1 && Number.isSafeInteger(body["version"]) && Number(body["version"]) > 0
    ? Number(body["version"]) : null;
}

function parseCloneBody(body: Record<string, unknown>): string | null {
  if (Object.keys(body).length !== 1 || typeof body["name"] !== "string") return null;
  const name = body["name"].trim();
  return name.length >= 1 && name.length <= 200 ? name : null;
}

function mutationResponse(result: ProductMutation, workspaceId: string, created = false): Response {
  if (result.status === "ok") return result.product.workspaceId === workspaceId
    ? response({ product: result.product }, created ? 201 : 200)
    : response({ error: "Serviço indisponível." }, 503);
  if (result.status === "duplicate") return response({ code: "duplicate", error: "Já existe um produto com esse nome neste espaço de trabalho." }, 409);
  if (result.status === "not_found") return response({ error: "Produto não encontrado." }, 404);
  return response({ code: "stale", error: "O produto foi alterado. Atualize a página e tente novamente." }, 409);
}

function cloneResponse(result: ProductCloneMutation, workspaceId: string): Response {
  if (result.status === "ok") return result.product.workspaceId === workspaceId
    ? response({ product: result.product, revisionId: result.revisionId, revisionLabel: "R00" }, 201)
    : response({ error: "Serviço indisponível." }, 503);
  if (result.status === "duplicate") return response({ code: "duplicate", error: "Já existe um produto com esse nome neste espaço de trabalho." }, 409);
  if (result.status === "not_found") return response({ error: "Produto não encontrado." }, 404);
  if (result.status === "denied") return response({ error: "Acesso não autorizado." }, 403);
  return response({ error: "Dados do produto inválidos." }, 400);
}

export function isProductRoute(pathname: string): boolean {
  return productPath.test(pathname);
}

export async function handleProductRequest(
  request: Request,
  identity: Identity,
  memberships: MembershipRepository,
  environment: WorkerEnvironment,
  repositoryFactory: ProductRepositoryFactory = createProductRepository
): Promise<Response> {
  const match = new URL(request.url).pathname.match(productPath);
  if (!match) return response({ error: "Não encontrado." }, 404);
  const [, workspaceId, productId, action] = match;
  if (!uuidPattern.test(workspaceId) || (productId && !uuidPattern.test(productId))) {
    return response({ error: "Identificador inválido." }, 400);
  }
  const write = request.method !== "GET";
  const membership = await authorizeWorkspace(identity, workspaceId, write ? "edit" : "read", memberships);
  if (!membership) return response({ error: "Acesso não autorizado." }, 403);
  const repository = repositoryFactory(environment);
  const scope = membership.workspaceId;
  const target = productId?.toLowerCase();

  if (request.method === "GET" && !target) {
    const products = await repository.list(scope);
    return products.every((product) => product.workspaceId === scope)
      ? response({ products }, 200) : response({ error: "Serviço indisponível." }, 503);
  }
  if (request.method === "GET" && target && !action) {
    const product = await repository.find(scope, target);
    return product && product.workspaceId === scope
      ? response({ product }, 200) : response({ error: "Produto não encontrado." }, 404);
  }
  if (request.method === "POST" && !target) {
    const body = await readBody(request);
    const parsed = body && parseProductInput(body, false);
    if (!parsed) return response({ error: "Dados do produto inválidos." }, 400);
    return mutationResponse(await repository.create(scope, identity.subject, parsed.input), scope, true);
  }
  if (request.method === "PATCH" && target && !action) {
    const body = await readBody(request);
    const parsed = body && parseProductInput(body, true);
    if (!parsed || parsed.version === undefined) return response({ error: "Dados do produto inválidos." }, 400);
    return mutationResponse(await repository.update(scope, target, identity.subject, parsed.input, parsed.version), scope);
  }
  if (request.method === "POST" && target && action === "archive") {
    const body = await readBody(request);
    const version = body && parseArchiveBody(body);
    if (version === null) return response({ error: "Dados do produto inválidos." }, 400);
    return mutationResponse(await repository.archive(scope, target, identity.subject, version), scope);
  }
  if (request.method === "POST" && target && action === "clone") {
    const body = await readBody(request);
    const name = body && parseCloneBody(body);
    if (!name) return response({ error: "Informe um nome de produto válido, com até 200 caracteres." }, 400);
    return cloneResponse(await repository.clone(scope, target, identity.subject, name), scope);
  }
  return response({ error: "Método não permitido." }, 405);
}
