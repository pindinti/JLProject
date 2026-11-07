import { neon } from "@neondatabase/serverless";
import type { WorkerEnvironment } from "./database";

export interface Product {
  id: string;
  workspaceId: string;
  name: string;
  description: string | null;
  active: boolean;
  version: number;
  createdAt: string;
  updatedAt: string;
}

export interface ProductInput { name: string; description: string | null }
export type ProductMutation = { status: "ok"; product: Product } |
  { status: "duplicate" | "not_found" | "stale" };

export interface ProductRepository {
  list(workspaceId: string): Promise<Product[]>;
  find(workspaceId: string, productId: string): Promise<Product | null>;
  create(workspaceId: string, actorId: string, input: ProductInput): Promise<ProductMutation>;
  update(workspaceId: string, productId: string, actorId: string, input: ProductInput, version: number): Promise<ProductMutation>;
  archive(workspaceId: string, productId: string, actorId: string, version: number): Promise<ProductMutation>;
}

function mapProduct(row: Record<string, unknown>): Product {
  const timestamp = (value: unknown) => new Date(value as string).toISOString();
  return {
    id: String(row["id"]), workspaceId: String(row["workspaceId"]),
    name: String(row["name"]), description: row["description"] === null ? null : String(row["description"]),
    active: row["active"] === true, version: Number(row["version"]),
    createdAt: timestamp(row["createdAt"]), updatedAt: timestamp(row["updatedAt"])
  };
}

function isUniqueViolation(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "23505";
}

export function createProductRepository(environment: WorkerEnvironment): ProductRepository {
  if (!environment.DATABASE_URL) throw new Error("Worker database configuration is missing.");
  const sql = neon(environment.DATABASE_URL);

  async function find(workspaceId: string, productId: string): Promise<Product | null> {
    const rows = await sql`
      SELECT id::text AS id, workspace_id::text AS "workspaceId", name, description,
             active, version, created_at AS "createdAt", updated_at AS "updatedAt"
      FROM public.products
      WHERE workspace_id = ${workspaceId}::uuid AND id = ${productId}::uuid
      LIMIT 1
    `;
    return rows[0] ? mapProduct(rows[0]) : null;
  }

  async function missingOrStale(workspaceId: string, productId: string): Promise<ProductMutation> {
    return await find(workspaceId, productId) ? { status: "stale" } : { status: "not_found" };
  }

  return {
    async list(workspaceId) {
      const rows = await sql`
        SELECT id::text AS id, workspace_id::text AS "workspaceId", name, description,
               active, version, created_at AS "createdAt", updated_at AS "updatedAt"
        FROM public.products
        WHERE workspace_id = ${workspaceId}::uuid
        ORDER BY active DESC, name, id
      `;
      return rows.map(mapProduct);
    },
    find,
    async create(workspaceId, actorId, input) {
      const rows = await sql`
        INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
        VALUES (${workspaceId}::uuid, ${input.name}, ${input.description}, ${actorId}::uuid, ${actorId}::uuid)
        ON CONFLICT DO NOTHING
        RETURNING id::text AS id, workspace_id::text AS "workspaceId", name, description,
                  active, version, created_at AS "createdAt", updated_at AS "updatedAt"
      `;
      return rows[0] ? { status: "ok", product: mapProduct(rows[0]) } : { status: "duplicate" };
    },
    async update(workspaceId, productId, actorId, input, version) {
      try {
        const rows = await sql`
          UPDATE public.products
          SET name = ${input.name}, description = ${input.description},
              updated_by = ${actorId}::uuid, updated_at = now(), version = version + 1
          WHERE workspace_id = ${workspaceId}::uuid AND id = ${productId}::uuid
            AND version = ${version} AND active = true
          RETURNING id::text AS id, workspace_id::text AS "workspaceId", name, description,
                    active, version, created_at AS "createdAt", updated_at AS "updatedAt"
        `;
        return rows[0] ? { status: "ok", product: mapProduct(rows[0]) } : missingOrStale(workspaceId, productId);
      } catch (error) {
        if (isUniqueViolation(error)) return { status: "duplicate" };
        throw error;
      }
    },
    async archive(workspaceId, productId, actorId, version) {
      const rows = await sql`
        UPDATE public.products
        SET active = false, updated_by = ${actorId}::uuid, updated_at = now(), version = version + 1
        WHERE workspace_id = ${workspaceId}::uuid AND id = ${productId}::uuid
          AND version = ${version} AND active = true
        RETURNING id::text AS id, workspace_id::text AS "workspaceId", name, description,
                  active, version, created_at AS "createdAt", updated_at AS "updatedAt"
      `;
      return rows[0] ? { status: "ok", product: mapProduct(rows[0]) } : missingOrStale(workspaceId, productId);
    }
  };
}
