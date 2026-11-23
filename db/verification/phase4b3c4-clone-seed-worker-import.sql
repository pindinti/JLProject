-- Create four isolated clone sources and their legitimate import-created R00 snapshots.
-- Run directly as jlproject_worker after the clone workspace owner seed has committed.
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

BEGIN;
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.phase4b3c4_clone_seed', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor')::text, true);

DO $preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_clone_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user,
       'public.import_initial_schedule(uuid,uuid,uuid,text,text,jsonb)', 'EXECUTE') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_actor AND active AND role IN ('admin', 'editor')) OR
     EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
       AND name IN ('Synthetic Phase 4B.3c.4 vigente source',
         'Synthetic Phase 4B.3c.4 study source', 'Synthetic Phase 4B.3c.4 archived source',
         'Synthetic Phase 4B.3c.4 empty source')) OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace) THEN
    RAISE EXCEPTION 'Expected a direct Worker session, empty synthetic workspace, and active editor.';
  END IF;
END;
$preflight$;

DO $import_sources$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_clone_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_actor uuid := (v_scope->>'actor')::uuid;
  v_source record;
  v_prefix text;
  v_payload jsonb;
  v_result jsonb;
  v_source_hash text;
  v_request_hash text;
  v_operation uuid;
BEGIN
  FOR v_source IN SELECT * FROM (VALUES
      ('vigente'), ('study'), ('archived'), ('empty')) AS sources(source_key)
  LOOP
    v_prefix := CASE v_source.source_key
      WHEN 'vigente' THEN 'CV' WHEN 'study' THEN 'CS'
      WHEN 'archived' THEN 'CA' ELSE 'CE' END;

    v_payload := jsonb_build_object(
      'idempotencyKey', md5('jlproject.phase4b3c4.import.' || v_source.source_key)::uuid,
      'productName', 'Synthetic Phase 4B.3c.4 ' || v_source.source_key || ' source',
      'sourceFilename', 'phase4b3c4-' || v_source.source_key || '.xlsx',
      'disciplines', (
        SELECT jsonb_agg(jsonb_build_object(
          'name', format('Synthetic %s discipline %s', v_source.source_key, discipline_no),
          'shortCode', format('D%s', discipline_no),
          'color', CASE discipline_no
            WHEN 1 THEN '#336699' WHEN 2 THEN '#386641' WHEN 3 THEN '#8C4A32'
            WHEN 4 THEN '#614C94' WHEN 5 THEN '#2F6F73' WHEN 6 THEN '#806026'
            ELSE '#8C3D62' END,
          'displayOrder', discipline_no - 1,
          'stages', (
            SELECT jsonb_agg(jsonb_build_object(
              'code', format('%s-D%s-S%s', v_prefix, discipline_no, stage_no),
              'color', '#336699',
              'displayName', format('%s-D%s-S%s', v_prefix, discipline_no, stage_no),
              'displayOrder', stage_no - 1,
              'activities', (
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'sourceId', 'T' || lpad(activity_no::text, 3, '0'),
                  'sourceRow', activity_no + 4,
                  'name', format('Synthetic %s activity %s', v_source.source_key,
                    lpad(activity_no::text, 3, '0')),
                  'activityType', 'Synthetic activity', 'status', NULL,
                  'notes', 'Synthetic source schedule activity',
                  'plannedStart', to_char(
                    DATE '2026-11-02' + ((activity_no - 1) / 5) * 7 + ((activity_no - 1) % 5),
                    'YYYY-MM-DD'),
                  'plannedEnd', to_char(
                    DATE '2026-11-02' + ((activity_no - 1) / 5) * 7 + ((activity_no - 1) % 5),
                    'YYYY-MM-DD'),
                  'displayOrder', activity_no + 4
                ) ORDER BY activity_no), '[]'::jsonb)
                FROM generate_series(1, 41) AS activities(activity_no)
                WHERE ((activity_no - 1) / 2) + 1 = ((discipline_no - 1) * 3) + stage_no
              )
            ) ORDER BY stage_no)
            FROM generate_series(1, 3) AS stages(stage_no)
          )
        ) ORDER BY discipline_no)
        FROM generate_series(1, 7) AS disciplines(discipline_no)
      ),
      'sourceMeta', (
        SELECT jsonb_agg(jsonb_build_object(
          'sourceId', 'T' || lpad(meta_no::text, 3, '0'), 'sourceRow', meta_no + 4,
          'name', format('Synthetic %s source meta %s', v_source.source_key, meta_no),
          'discipline', format('Synthetic %s discipline 1', v_source.source_key),
          'stage', format('%s-D1-S1', v_prefix),
          'plannedStart', '2026-11-02', 'plannedEnd', '2026-11-03',
          'status', NULL, 'notes', 'Synthetic matched target metadata'
        ) ORDER BY meta_no)
        FROM generate_series(42, 46) AS metadata(meta_no)
      ),
      'targets', (
        SELECT jsonb_agg(jsonb_build_object(
          'name', format('Synthetic %s source meta %s', v_source.source_key, meta_no),
          'sourceRow', meta_no - 38, 'targetDate', '2026-11-02',
          'operationalDate', NULL, 'status', NULL,
          'notes', 'Synthetic target fixture', 'displayOrder', meta_no - 42,
          'matchedSourceId', 'T' || lpad(meta_no::text, 3, '0'), 'matchMethod', 'exact'
        ) ORDER BY meta_no)
        FROM generate_series(42, 46) AS targets(meta_no)
      )
    );

    -- The database import contract stores 64-character lowercase hash tokens and does not
    -- recompute Worker canonical hashes. These deterministic fixture digests satisfy
    -- that contract without requiring an unapproved extension or privilege.
    v_source_hash := md5('source:' || v_source.source_key) || md5(v_payload::text);
    v_request_hash := md5('request:' || v_source.source_key) || md5(v_payload::text || ':request');
    v_operation := md5('jlproject.phase4b3c4.import-operation.' || v_source.source_key)::uuid;
    PERFORM set_config('jlproject.schedule_actor_id', v_actor::text, true);
    PERFORM set_config('jlproject.schedule_operation_id', v_operation::text, true);
    PERFORM set_config('jlproject.schedule_operation_type', 'schedule_imported', true);
    PERFORM set_config('jlproject.schedule_justification',
      'Synthetic clone source initial schedule import', true);

    v_result := public.import_initial_schedule(v_workspace, v_actor,
      (v_payload->>'idempotencyKey')::uuid, v_source_hash, v_request_hash, v_payload);
    IF v_result->>'status' IS DISTINCT FROM 'created' OR
       v_result->>'revisionLabel' IS DISTINCT FROM 'R00' THEN
      RAISE EXCEPTION 'Synthetic % source import failed: %', v_source.source_key, v_result;
    END IF;
    RAISE NOTICE 'CLONE_SOURCE|%|%|%', v_source.source_key,
      v_result->>'productId', v_result->>'revisionId';
  END LOOP;
END;
$import_sources$;

DO $postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c4_clone_seed')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
BEGIN
  IF (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace
        AND name IN ('Synthetic Phase 4B.3c.4 vigente source',
          'Synthetic Phase 4B.3c.4 study source', 'Synthetic Phase 4B.3c.4 archived source',
          'Synthetic Phase 4B.3c.4 empty source')) <> 4 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace
        AND import_batch_id IS NOT NULL AND label = 'R00'
        AND snapshot->'dependencies' = '[]'::jsonb) <> 4 THEN
    RAISE EXCEPTION 'The four source imports must create empty-graph R00 baselines.';
  END IF;
END;
$postflight$;

COMMIT;
