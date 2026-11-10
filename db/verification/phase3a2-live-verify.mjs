import { readFileSync } from "node:fs";
import process from "node:process";
import { URL } from "node:url";
import { neon } from "@neondatabase/serverless";

const sourceName = "Synthetic 1C2 1794101573919";
const cloneName = "Synthetic 3A2 browser check";
const settings = readFileSync(".dev.vars", "utf8");
const match = settings.match(/^DATABASE_URL=(?:"([^"]+)"|([^\r\n]+))$/m);
if (!match) throw new Error("Local Worker database configuration is missing.");

const databaseUrl = new URL(match[1] ?? match[2]);
if (databaseUrl.username !== "jlproject_worker" || databaseUrl.pathname !== "/neondb") {
  throw new Error("The read-only check requires the JLProject development Worker connection.");
}

const sql = neon(databaseUrl.toString());
const connection = await sql`SELECT current_user AS role, current_database() AS database`;
if (connection[0]?.["role"] !== "jlproject_worker" || connection[0]?.["database"] !== "neondb") {
  throw new Error("The read-only check connected with an unexpected database role or database.");
}
const products = await sql`SELECT p.id::text AS id, p.workspace_id::text AS workspace_id, p.name
  FROM public.products AS p
  JOIN public.workspaces AS w ON w.id = p.workspace_id
  WHERE w.name = 'JLProject' AND p.name IN (${sourceName}, ${cloneName}) AND p.active = true`;
const sources = products.filter((product) => product["name"] === sourceName);
const clones = products.filter((product) => product["name"] === cloneName);
if (sources.length !== 1 || clones.length !== 1 ||
    sources[0]["workspace_id"] !== clones[0]["workspace_id"]) {
  throw new Error("Expected exactly one synthetic source and one same-workspace clone.");
}

const sourceId = String(sources[0]["id"]);
const cloneId = String(clones[0]["id"]);

async function counts(productId) {
  const rows = await sql`SELECT
    (SELECT count(*)::int FROM public.product_disciplines WHERE product_id = ${productId}::uuid) AS disciplines,
    (SELECT count(*)::int FROM public.discipline_stages WHERE product_id = ${productId}::uuid) AS stages,
    (SELECT count(*)::int FROM public.stage_activities WHERE product_id = ${productId}::uuid) AS activities,
    (SELECT count(*)::int FROM public.business_targets
      WHERE product_id = ${productId}::uuid AND deleted_at IS NULL) AS targets,
    (SELECT count(*)::int FROM public.initial_schedule_revisions WHERE product_id = ${productId}::uuid) AS revisions,
    (SELECT count(*)::int FROM public.import_batches WHERE product_id = ${productId}::uuid) AS import_batches,
    (SELECT count(*)::int FROM public.import_source_rows AS r
      JOIN public.import_batches AS b ON b.id = r.import_batch_id
      WHERE b.product_id = ${productId}::uuid) AS import_source_rows,
    (SELECT count(*)::int FROM public.activity_date_changes WHERE product_id = ${productId}::uuid) AS activity_audit,
    (SELECT count(*)::int FROM public.business_target_date_changes WHERE product_id = ${productId}::uuid) AS target_audit,
    (SELECT count(*)::int FROM public.stage_activities
      WHERE product_id = ${productId}::uuid AND source_external_id IS NOT NULL) AS activity_import_ids,
    (SELECT count(*)::int FROM public.business_targets
      WHERE product_id = ${productId}::uuid AND
        (source_external_id IS NOT NULL OR source_row IS NOT NULL)) AS target_import_ids`;
  return rows[0];
}

async function contentDigest(productId) {
  const rows = await sql`SELECT md5(jsonb_build_object(
    'disciplines', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'name', d.name, 'shortCode', d.short_code, 'color', d.color,
      'displayOrder', d.display_order, 'description', d.description
    ) ORDER BY d.display_order, d.name), '[]'::jsonb)
      FROM public.product_disciplines AS d WHERE d.product_id = ${productId}::uuid),
    'stages', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'discipline', d.name, 'definitionId', s.definition_id, 'code', sd.code,
      'definitionColor', sd.color, 'displayName', s.display_name, 'displayOrder', s.display_order
    ) ORDER BY d.display_order, s.display_order, d.name, sd.code), '[]'::jsonb)
      FROM public.discipline_stages AS s
      JOIN public.product_disciplines AS d ON d.id = s.discipline_id
      JOIN public.stage_definitions AS sd ON sd.id = s.definition_id
      WHERE s.product_id = ${productId}::uuid),
    'activities', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'discipline', d.name, 'stage', s.display_name, 'name', a.name,
      'activityType', a.activity_type, 'plannedStart', a.planned_start,
      'plannedEnd', a.planned_end, 'displayOrder', a.display_order, 'notes', a.notes
    ) ORDER BY d.display_order, s.display_order, a.display_order, a.name), '[]'::jsonb)
      FROM public.stage_activities AS a
      JOIN public.product_disciplines AS d ON d.id = a.discipline_id
      JOIN public.discipline_stages AS s ON s.id = a.stage_id
      WHERE a.product_id = ${productId}::uuid),
    'targets', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'name', t.name, 'targetDate', t.target_date, 'operationalDate', t.operational_date,
      'displayOrder', t.display_order, 'description', t.description, 'color', t.color
    ) ORDER BY t.display_order, t.name), '[]'::jsonb)
      FROM public.business_targets AS t
      WHERE t.product_id = ${productId}::uuid AND t.deleted_at IS NULL)
  )::text) AS digest`;
  return String(rows[0]?.["digest"] ?? "");
}

const sourceCounts = await counts(sourceId);
const cloneCounts = await counts(cloneId);
const sourceContentDigest = await contentDigest(sourceId);
const cloneContentDigest = await contentDigest(cloneId);
const revisionRows = await sql`SELECT import_batch_id::text AS import_batch_id, snapshot
  FROM public.initial_schedule_revisions WHERE product_id = ${cloneId}::uuid`;
const sourceDigestRows = await sql`SELECT md5(jsonb_build_object(
  'product', (SELECT to_jsonb(p) FROM public.products AS p WHERE p.id = ${sourceId}::uuid),
  'disciplines', (SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.id), '[]'::jsonb)
    FROM public.product_disciplines AS d WHERE d.product_id = ${sourceId}::uuid),
  'stages', (SELECT COALESCE(jsonb_agg(jsonb_build_object('stage', to_jsonb(s), 'definition', to_jsonb(sd))
      ORDER BY s.id), '[]'::jsonb)
    FROM public.discipline_stages AS s JOIN public.stage_definitions AS sd ON sd.id = s.definition_id
    WHERE s.product_id = ${sourceId}::uuid),
  'activities', (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.id), '[]'::jsonb)
    FROM public.stage_activities AS a WHERE a.product_id = ${sourceId}::uuid),
  'targets', (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]'::jsonb)
    FROM public.business_targets AS t WHERE t.product_id = ${sourceId}::uuid),
  'batches', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.id), '[]'::jsonb)
    FROM public.import_batches AS b WHERE b.product_id = ${sourceId}::uuid),
  'sourceRows', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.source_sheet, r.source_row), '[]'::jsonb)
    FROM public.import_source_rows AS r JOIN public.import_batches AS b ON b.id = r.import_batch_id
    WHERE b.product_id = ${sourceId}::uuid),
  'r00', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]'::jsonb)
    FROM public.initial_schedule_revisions AS r WHERE r.product_id = ${sourceId}::uuid),
  'activityAudit', (SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.operation_id), '[]'::jsonb)
    FROM public.activity_date_changes AS e WHERE e.product_id = ${sourceId}::uuid),
  'targetAudit', (SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.operation_id), '[]'::jsonb)
    FROM public.business_target_date_changes AS e WHERE e.product_id = ${sourceId}::uuid)
)::text) AS digest`;

const revision = revisionRows[0];
const snapshot = revision?.["snapshot"];
const snapshotProductId = snapshot?.product?.id;
const snapshotIsIndependent = revisionRows.length === 1 && revision?.["import_batch_id"] === null &&
  snapshotProductId === cloneId && Array.isArray(snapshot?.sourceMeta) && snapshot.sourceMeta.length === 0 &&
  Array.isArray(snapshot?.dependencies) && snapshot.dependencies.length === 0 &&
  snapshot?.activityIds && Object.keys(snapshot.activityIds).length === 0;

const sharedDefinitions = await sql`WITH source_definitions AS (
    SELECT DISTINCT definition_id FROM public.discipline_stages WHERE product_id = ${sourceId}::uuid
  ), clone_definitions AS (
    SELECT DISTINCT definition_id FROM public.discipline_stages WHERE product_id = ${cloneId}::uuid
  )
  SELECT
    NOT EXISTS (SELECT definition_id FROM source_definitions EXCEPT SELECT definition_id FROM clone_definitions)
      AS source_set_present,
    NOT EXISTS (SELECT definition_id FROM clone_definitions EXCEPT SELECT definition_id FROM source_definitions)
      AS clone_set_present,
    (SELECT count(*)::int FROM public.stage_definitions AS d
      WHERE d.id IN (SELECT definition_id FROM clone_definitions)
        AND d.id NOT IN (SELECT definition_id FROM source_definitions)) AS new_definition_count`;

const overlappingIds = await sql`SELECT
  (SELECT count(*)::int FROM public.product_disciplines a JOIN public.product_disciplines b USING (id)
    WHERE a.product_id = ${sourceId}::uuid AND b.product_id = ${cloneId}::uuid) +
  (SELECT count(*)::int FROM public.discipline_stages a JOIN public.discipline_stages b USING (id)
    WHERE a.product_id = ${sourceId}::uuid AND b.product_id = ${cloneId}::uuid) +
  (SELECT count(*)::int FROM public.stage_activities a JOIN public.stage_activities b USING (id)
    WHERE a.product_id = ${sourceId}::uuid AND b.product_id = ${cloneId}::uuid) +
  (SELECT count(*)::int FROM public.business_targets a JOIN public.business_targets b USING (id)
    WHERE a.product_id = ${sourceId}::uuid AND b.product_id = ${cloneId}::uuid) AS overlaps`;

const clone = cloneCounts;
const sourceFingerprintUnchanged = String(sourceDigestRows[0]?.["digest"] ?? "") ===
  "9621472ec83a5a9c516773b94944898f";
const contentMatches = sourceContentDigest !== "" && sourceContentDigest === cloneContentDigest;
const stageDefinitionsShared = Boolean(sharedDefinitions[0]?.["source_set_present"] &&
  sharedDefinitions[0]?.["clone_set_present"] && Number(sharedDefinitions[0]?.["new_definition_count"]) === 0);
const noImportProvenance = Number(clone?.["import_batches"]) === 0 &&
  Number(clone?.["import_source_rows"]) === 0 && Number(clone?.["activity_import_ids"]) === 0 &&
  Number(clone?.["target_import_ids"]) === 0;
const noAuditHistory = Number(clone?.["activity_audit"]) === 0 && Number(clone?.["target_audit"]) === 0;
const correctCounts = Number(sourceCounts?.["disciplines"]) === 7 && Number(sourceCounts?.["stages"]) === 21 &&
  Number(sourceCounts?.["activities"]) === 41 && Number(sourceCounts?.["targets"]) === 5 &&
  Number(clone?.["disciplines"]) === 7 && Number(clone?.["stages"]) === 21 &&
  Number(clone?.["activities"]) === 41 && Number(clone?.["targets"]) === 5 && Number(clone?.["revisions"]) === 1;

const result = {
  target: "JLProject development / limited Worker",
  sourceCounts: {
    disciplines: Number(sourceCounts["disciplines"]), stages: Number(sourceCounts["stages"]),
    activities: Number(sourceCounts["activities"]), targets: Number(sourceCounts["targets"]),
  },
  cloneCounts: {
    disciplines: Number(clone["disciplines"]), stages: Number(clone["stages"]),
    activities: Number(clone["activities"]), targets: Number(clone["targets"]), revisions: Number(clone["revisions"]),
  },
  sourceFingerprintUnchanged,
  contentMatches,
  stageDefinitionsShared,
  newProductSpecificIds: Number(overlappingIds[0]?.["overlaps"]) === 0,
  noImportProvenance,
  noAuditHistory,
  independentImmutableR00: snapshotIsIndependent,
  allChecksPass: sourceFingerprintUnchanged && contentMatches && stageDefinitionsShared &&
    Number(overlappingIds[0]?.["overlaps"]) === 0 && noImportProvenance && noAuditHistory &&
    snapshotIsIndependent && correctCounts,
};

process.stdout.write(`${JSON.stringify(result)}\n`);
if (!result.allChecksPass) process.exitCode = 1;
