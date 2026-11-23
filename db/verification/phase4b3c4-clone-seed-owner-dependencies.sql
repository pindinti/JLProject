-- Add three audited, valid dependency edges to each linked clone source.
-- Run as neondb_owner after the direct Worker import and schedule setup have committed.
\set ON_ERROR_STOP on
\if :{?phase4b5_disposable_child_verified}
\else
\set phase4b5_disposable_child_verified false
\endif
\if :phase4b5_disposable_child_verified
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A verified disposable Development child is required.'; END; $$;
\endif
\if :{?test_workspace}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_workspace from phase4b3c4-clone-seed-owner.sql.'; END; $$;
\endif
\if :{?test_actor}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply test_actor from phase4b3c4-clone-seed-owner.sql.'; END; $$;
\endif
\if :{?historical_r00_count}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply historical_r00_count and historical_r00_fingerprint from the owner workspace seed.'; END; $$;
\endif
\if :{?historical_r00_fingerprint}
\else
DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Supply historical_r00_fingerprint from the owner workspace seed.'; END; $$;
\endif

SELECT id::text AS vigente_source FROM public.products WHERE workspace_id = :'test_workspace'::uuid
  AND name = 'Synthetic Phase 4B.3c.4 vigente source' \gset
SELECT id::text AS study_source FROM public.products WHERE workspace_id = :'test_workspace'::uuid
  AND name = 'Synthetic Phase 4B.3c.4 study source' \gset
SELECT id::text AS archived_source FROM public.products WHERE workspace_id = :'test_workspace'::uuid
  AND name = 'Synthetic Phase 4B.3c.4 archived source' \gset
SELECT id::text AS empty_source FROM public.products WHERE workspace_id = :'test_workspace'::uuid
  AND name = 'Synthetic Phase 4B.3c.4 empty source' \gset

SELECT set_config('jlproject.phase4b3c4_edge_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor',
  'vigente', :'vigente_source', 'study', :'study_source',
  'archived', :'archived_source', 'empty', :'empty_source',
  'historicalCount', :'historical_r00_count',
  'historicalFingerprint', :'historical_r00_fingerprint')::text, false);

DO $preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_edge_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_source record;
  v_count bigint;
  v_fingerprint text;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') OR
     (SELECT count(*) FROM public.initial_schedule_revisions) <> 10 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace
       AND import_batch_id IS NOT NULL AND label = 'R00'
       AND snapshot->'dependencies' = '[]'::jsonb) <> 4 OR
     EXISTS (SELECT 1 FROM public.product_schedule_dependencies WHERE workspace_id = v_workspace) THEN
    RAISE EXCEPTION 'Expected six original R00 rows, four imported empty-graph R00 rows, and no source edges.';
  END IF;
  SELECT count(*)::bigint,
    md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    INTO v_count, v_fingerprint
  FROM public.initial_schedule_revisions AS revision WHERE revision.workspace_id <> v_workspace;
  IF v_count <> (v_scope->>'historicalCount')::bigint OR
     v_fingerprint IS DISTINCT FROM v_scope->>'historicalFingerprint' THEN
    RAISE EXCEPTION 'Historical R00 rows changed between clone workspace and source setup.';
  END IF;

  FOR v_source IN SELECT * FROM (VALUES
      ((v_scope->>'vigente')::uuid, 'vigente', '4b440000-0000-4000-8000-000000000311'::uuid),
      ((v_scope->>'study')::uuid, 'study', NULL::uuid),
      ((v_scope->>'archived')::uuid, 'archived', '4b440000-0000-4000-8000-000000000312'::uuid),
      ((v_scope->>'empty')::uuid, 'empty', NULL::uuid)) AS expected(id, source_key, root_operation_id)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
        AND id = v_source.id AND created_by = v_actor AND active
        AND planning_classification = 'vigente') OR
       (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace
         AND product_id = v_source.id AND deleted_at IS NULL) <> 21 OR
       (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
         AND product_id = v_source.id AND deleted_at IS NULL AND stage_id IS NOT NULL) <> 41 OR
       (SELECT count(*) FROM public.business_targets WHERE workspace_id = v_workspace
         AND product_id = v_source.id) <> 5 OR
       (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
         AND product_id = v_source.id AND deleted_at IS NULL AND stage_id IS NULL
           AND discipline_id IS NULL) <> (CASE WHEN v_source.root_operation_id IS NOT NULL THEN 2 ELSE 0 END) OR
       (SELECT count(*) FROM public.stage_date_changes WHERE workspace_id = v_workspace
         AND product_id = v_source.id) <> 2 THEN
      RAISE EXCEPTION 'Imported schedule, stage dates, or root activities are incomplete for source %.',
        v_source.source_key;
    END IF;

    -- Each known root setup operation must contain two creation events for two distinct roots.
    IF v_source.root_operation_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.product_schedule_operations AS operation
      JOIN public.product_schedule_operation_events AS event
        ON event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
        AND event.schedule_version = operation.schedule_version AND event.operation_id = operation.operation_id
      LEFT JOIN public.stage_activities AS root
        ON root.workspace_id = event.workspace_id AND root.product_id = event.product_id
        AND root.id = event.entity_id AND root.deleted_at IS NULL
        AND root.stage_id IS NULL AND root.discipline_id IS NULL
      WHERE operation.workspace_id = v_workspace AND operation.product_id = v_source.id
        AND operation.operation_id = v_source.root_operation_id AND operation.actor_id = v_actor
        AND operation.operation_type = 'activity_created_with_dates'
        AND operation.justification = 'Synthetic clone source root activity setup'
        AND event.entity_type = 'stage_activities' AND event.change_type = 'stage_activities_created'
      HAVING count(*) = 2 AND count(DISTINCT root.id) = 2
    ) THEN
      RAISE EXCEPTION 'Expected two distinct root creation events for source % under operation %.',
        v_source.source_key, v_source.root_operation_id;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace
        AND product_id IN ((v_scope->>'vigente')::uuid, (v_scope->>'archived')::uuid)
        AND planning_mode = 'working_days' AND working_day_duration = 1
        AND planning_calendar_version = 0 AND deleted_at IS NULL
        AND stage_id IS NULL AND discipline_id IS NULL) <> 4 OR
     (SELECT count(*) FROM public.product_schedule_operations operation
        WHERE operation.workspace_id = v_workspace
          AND operation.product_id IN ((v_scope->>'vigente')::uuid, (v_scope->>'archived')::uuid)
          AND operation.operation_type = 'activity_created_with_dates'
          AND operation.justification = 'Synthetic clone source root activity setup') <> 2 OR
     (SELECT count(*) FROM public.stage_date_changes change
        WHERE change.workspace_id = v_workspace
          AND change.reason = 'Synthetic clone source D065 date setup') <> 8 THEN
    RAISE EXCEPTION 'Root working-plan assumptions or source schedule audit grouping are incorrect.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.discipline_stages stage
      JOIN public.product_disciplines discipline ON discipline.workspace_id = stage.workspace_id
        AND discipline.product_id = stage.product_id AND discipline.id = stage.discipline_id
      WHERE stage.workspace_id = v_workspace AND stage.product_id IN (
        (v_scope->>'vigente')::uuid, (v_scope->>'study')::uuid,
        (v_scope->>'archived')::uuid, (v_scope->>'empty')::uuid)
        AND discipline.short_code = 'D1' AND stage.display_name LIKE '%-D1-S1'
        AND (stage.planned_start IS DISTINCT FROM DATE '2026-11-02' OR
             stage.planned_end IS DISTINCT FROM DATE '2026-11-03')) OR
     EXISTS (SELECT 1 FROM public.discipline_stages stage
      JOIN public.product_disciplines discipline ON discipline.workspace_id = stage.workspace_id
        AND discipline.product_id = stage.product_id AND discipline.id = stage.discipline_id
      WHERE stage.workspace_id = v_workspace AND stage.product_id IN (
        (v_scope->>'vigente')::uuid, (v_scope->>'study')::uuid,
        (v_scope->>'archived')::uuid, (v_scope->>'empty')::uuid)
        AND discipline.short_code = 'D1' AND stage.display_name LIKE '%-D1-S2'
        AND (stage.planned_start IS NOT NULL OR stage.planned_end IS DISTINCT FROM DATE '2026-11-05')) THEN
    RAISE EXCEPTION 'Clone source complete and partial explicit stage boundaries differ from D065 seed expectations.';
  END IF;
END;
$preflight$;

-- Vigente: root-to-root activity, source activity, and cross-discipline stage edge.
\set test_product :vigente_source
SELECT id::text AS test_predecessor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'vigente_source'::uuid AND name = 'Synthetic vigente root predecessor' \gset
SELECT id::text AS test_successor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'vigente_source'::uuid AND name = 'Synthetic vigente root successor' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000101
\set test_endpoint_kind activity
\set test_operation_id 4b440000-0000-4000-8000-000000000201
\i db/verification/phase4b5-seed-one-dependency.sql
SELECT id::text AS test_predecessor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'vigente_source'::uuid AND source_external_id = 'T001' \gset
SELECT id::text AS test_successor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'vigente_source'::uuid AND source_external_id = 'T002' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000102
\set test_operation_id 4b440000-0000-4000-8000-000000000202
\i db/verification/phase4b5-seed-one-dependency.sql
SELECT stage.id::text AS test_predecessor_id FROM public.discipline_stages stage
  JOIN public.product_disciplines discipline ON discipline.id = stage.discipline_id
  WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'vigente_source'::uuid
    AND discipline.short_code = 'D1' AND stage.display_name = 'CV-D1-S3' \gset
SELECT stage.id::text AS test_successor_id FROM public.discipline_stages stage
  JOIN public.product_disciplines discipline ON discipline.id = stage.discipline_id
  WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'vigente_source'::uuid
    AND discipline.short_code = 'D2' AND stage.display_name = 'CV-D2-S1' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000103
\set test_endpoint_kind stage
\set test_operation_id 4b440000-0000-4000-8000-000000000203
\i db/verification/phase4b5-seed-one-dependency.sql

-- Em estudo source: two activity links and one cross-discipline stage link.
\set test_product :study_source
SELECT id::text AS test_predecessor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'study_source'::uuid AND source_external_id = 'T001' \gset
SELECT id::text AS test_successor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'study_source'::uuid AND source_external_id = 'T002' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000104
\set test_endpoint_kind activity
\set test_operation_id 4b440000-0000-4000-8000-000000000204
\i db/verification/phase4b5-seed-one-dependency.sql
SELECT id::text AS test_predecessor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'study_source'::uuid AND source_external_id = 'T003' \gset
SELECT id::text AS test_successor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'study_source'::uuid AND source_external_id = 'T004' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000105
\set test_operation_id 4b440000-0000-4000-8000-000000000205
\i db/verification/phase4b5-seed-one-dependency.sql
SELECT stage.id::text AS test_predecessor_id FROM public.discipline_stages stage
  JOIN public.product_disciplines discipline ON discipline.id = stage.discipline_id
  WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'study_source'::uuid
    AND discipline.short_code = 'D1' AND stage.display_name = 'CS-D1-S3' \gset
SELECT stage.id::text AS test_successor_id FROM public.discipline_stages stage
  JOIN public.product_disciplines discipline ON discipline.id = stage.discipline_id
  WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'study_source'::uuid
    AND discipline.short_code = 'D2' AND stage.display_name = 'CS-D2-S1' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000106
\set test_endpoint_kind stage
\set test_operation_id 4b440000-0000-4000-8000-000000000206
\i db/verification/phase4b5-seed-one-dependency.sql

-- Arquivado source: root-to-root activity, source activity, and cross-discipline stage edge.
\set test_product :archived_source
SELECT id::text AS test_predecessor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'archived_source'::uuid AND name = 'Synthetic archived root predecessor' \gset
SELECT id::text AS test_successor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'archived_source'::uuid AND name = 'Synthetic archived root successor' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000107
\set test_endpoint_kind activity
\set test_operation_id 4b440000-0000-4000-8000-000000000207
\i db/verification/phase4b5-seed-one-dependency.sql
SELECT id::text AS test_predecessor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'archived_source'::uuid AND source_external_id = 'T001' \gset
SELECT id::text AS test_successor_id FROM public.stage_activities WHERE workspace_id = :'test_workspace'::uuid
  AND product_id = :'archived_source'::uuid AND source_external_id = 'T002' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000108
\set test_endpoint_kind activity
\set test_operation_id 4b440000-0000-4000-8000-000000000208
\i db/verification/phase4b5-seed-one-dependency.sql
SELECT stage.id::text AS test_predecessor_id FROM public.discipline_stages stage
  JOIN public.product_disciplines discipline ON discipline.id = stage.discipline_id
  WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'archived_source'::uuid
    AND discipline.short_code = 'D1' AND stage.display_name = 'CA-D1-S3' \gset
SELECT stage.id::text AS test_successor_id FROM public.discipline_stages stage
  JOIN public.product_disciplines discipline ON discipline.id = stage.discipline_id
  WHERE stage.workspace_id = :'test_workspace'::uuid AND stage.product_id = :'archived_source'::uuid
    AND discipline.short_code = 'D2' AND stage.display_name = 'CA-D2-S1' \gset
\set test_edge_id 4b440000-0000-4000-8000-000000000109
\set test_endpoint_kind stage
\set test_operation_id 4b440000-0000-4000-8000-000000000209
\i db/verification/phase4b5-seed-one-dependency.sql

DO $postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_edge_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_count bigint;
  v_fingerprint text;
  v_source record;
BEGIN
  SELECT count(*)::bigint,
    md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    INTO v_count, v_fingerprint
  FROM public.initial_schedule_revisions AS revision WHERE revision.workspace_id <> v_workspace;
  IF v_count <> (v_scope->>'historicalCount')::bigint OR
     v_fingerprint IS DISTINCT FROM v_scope->>'historicalFingerprint' OR
     (SELECT count(*) FROM public.initial_schedule_revisions) <> 10 THEN
    RAISE EXCEPTION 'Dependency fixture changed historical or source R00 rows.';
  END IF;
  FOR v_source IN SELECT id FROM (VALUES
      ((v_scope->>'vigente')::uuid), ((v_scope->>'study')::uuid),
      ((v_scope->>'archived')::uuid)) AS linked(id)
  LOOP
    IF (SELECT count(*) FROM public.product_schedule_dependencies WHERE workspace_id = v_workspace
          AND product_id = v_source.id) <> 3 OR
       (SELECT count(DISTINCT endpoint_kind) FROM public.product_schedule_dependencies
          WHERE workspace_id = v_workspace AND product_id = v_source.id) <> 2 OR
       (SELECT count(*) FROM public.product_schedule_operation_events WHERE workspace_id = v_workspace
          AND product_id = v_source.id AND entity_type = 'product_schedule_dependencies'
          AND change_type = 'dependency_added') <> 3 THEN
      RAISE EXCEPTION 'Expected three audited edges covering both endpoint kinds for product %.', v_source.id;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.product_schedule_dependencies WHERE workspace_id = v_workspace
      AND product_id = (v_scope->>'empty')::uuid) THEN
    RAISE EXCEPTION 'Empty source must retain an empty working dependency graph.';
  END IF;
END;
$postflight$;

\echo Clone dependency source seed committed. Capture these variables for the clone preflight:
\echo test_workspace=:test_workspace test_actor=:test_actor vigente_source=:vigente_source study_source=:study_source archived_source=:archived_source empty_source=:empty_source
\echo Clone preflight and Worker variables: workspace=:test_workspace editor=:test_actor viewer=:test_viewer other_workspace=:test_other_workspace vigente_source=:vigente_source study_source=:study_source archived_source=:archived_source empty_source=:empty_source
\echo historical_r00_count=:historical_r00_count historical_r00_fingerprint=:historical_r00_fingerprint
\echo Use missing_target_name=Synthetic Phase 4B.3c.4 incomplete remap target
\echo Root activity dependency endpoints are emitted by the clone preflight ROOT_EDGE row.
