-- Run in a separate read-only neondb_owner session before the direct Worker fixture.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.test_clone_scope', jsonb_build_object('workspace', :'workspace',
  'editor', :'editor', 'viewer', :'viewer', 'otherWorkspace', :'other_workspace',
  'vigente', :'vigente_source', 'study', :'study_source', 'archived', :'archived_source',
  'empty', :'empty_source')::text, true);

DO $owner_preflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.test_clone_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_editor uuid := (v_scope->>'editor')::uuid;
  v_source record;
  v_historical_r00_count bigint;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     NOT has_function_privilege('jlproject_worker', 'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker', 'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.products', 'INSERT') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Clone fixture role permissions differ from the reviewed direct-Worker contract.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_editor AND active AND role IN ('admin', 'editor')) OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = (v_scope->>'viewer')::uuid AND active AND role = 'viewer') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = (v_scope->>'otherWorkspace')::uuid
       AND auth_user_id = v_editor AND active AND role IN ('admin', 'editor')) THEN
    RAISE EXCEPTION 'Clone actors are missing active workspace memberships.';
  END IF;
  FOR v_source IN SELECT * FROM (VALUES
      ((v_scope->>'vigente')::uuid, 'vigente'), ((v_scope->>'study')::uuid, 'em_estudo'),
      ((v_scope->>'archived')::uuid, 'arquivado'), ((v_scope->>'empty')::uuid, 'vigente')) AS expected(id, status)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.workspace_id = v_workspace AND p.id = v_source.id
      AND (CASE WHEN p.active THEN p.planning_classification ELSE 'arquivado' END) = v_source.status) THEN
      RAISE EXCEPTION 'Clone source % does not have expected status %.', v_source.id, v_source.status;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM (VALUES ((v_scope->>'vigente')::uuid),
        ((v_scope->>'study')::uuid), ((v_scope->>'archived')::uuid)) AS linked_sources(id)
      WHERE (SELECT count(*) FROM public.product_schedule_dependencies edge
          WHERE edge.workspace_id = v_workspace AND edge.product_id = linked_sources.id) < 3 OR
        (SELECT count(DISTINCT endpoint_kind) FROM public.product_schedule_dependencies edge
          WHERE edge.workspace_id = v_workspace AND edge.product_id = linked_sources.id) <> 2) OR
     NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies edge
       JOIN public.stage_activities predecessor ON predecessor.id = edge.predecessor_activity_id
         AND predecessor.stage_id IS NULL AND predecessor.discipline_id IS NULL AND predecessor.deleted_at IS NULL
       JOIN public.stage_activities successor ON successor.id = edge.successor_activity_id
         AND successor.stage_id IS NULL AND successor.discipline_id IS NULL AND successor.deleted_at IS NULL
       WHERE edge.workspace_id = v_workspace AND edge.product_id = (v_scope->>'vigente')::uuid
         AND edge.endpoint_kind = 'activity') OR
     NOT EXISTS (SELECT 1 FROM public.product_schedule_dependencies edge
       JOIN public.stage_activities predecessor ON predecessor.id = edge.predecessor_activity_id
         AND predecessor.stage_id IS NULL AND predecessor.discipline_id IS NULL AND predecessor.deleted_at IS NULL
       JOIN public.stage_activities successor ON successor.id = edge.successor_activity_id
         AND successor.stage_id IS NULL AND successor.discipline_id IS NULL AND successor.deleted_at IS NULL
       WHERE edge.workspace_id = v_workspace AND edge.product_id = (v_scope->>'archived')::uuid
         AND edge.endpoint_kind = 'activity') OR
     EXISTS (SELECT 1 FROM public.product_schedule_dependencies
       WHERE workspace_id = v_workspace AND product_id = (v_scope->>'empty')::uuid) THEN
    RAISE EXCEPTION 'Clone sources do not have the required linked and empty graph shapes.';
  END IF;
  SELECT count(*)::bigint INTO v_historical_r00_count
  FROM public.initial_schedule_revisions WHERE workspace_id <> v_workspace;
  IF v_historical_r00_count <> 6 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace
       AND import_batch_id IS NOT NULL AND label = 'R00'
       AND snapshot->'dependencies' = '[]'::jsonb) <> 4 OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace
       AND snapshot->'dependencies' IS DISTINCT FROM '[]'::jsonb) THEN
    RAISE EXCEPTION 'Expected six unchanged historical R00 rows and four import-created empty-graph source R00 rows.';
  END IF;
END;
$owner_preflight$;

SELECT 'OWNER_CAN_SET_WORKER' AS record_type,
  pg_has_role('neondb_owner', 'jlproject_worker', 'SET') AS can_set_worker_role;

-- Save these source_id/fingerprint pairs. The owner postflight must receive the same values.
WITH scope AS (SELECT current_setting('jlproject.test_clone_scope')::jsonb AS value),
sources AS (
  SELECT jsonb_array_elements_text(jsonb_build_array(value->>'vigente', value->>'study',
    value->>'archived', value->>'empty'))::uuid AS id FROM scope
), source_state AS (
  SELECT p.id, jsonb_build_object(
    'product', to_jsonb(p),
    'activities', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
      FROM public.stage_activities a WHERE a.product_id = p.id), '[]'::jsonb),
    'stages', COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id)
      FROM public.discipline_stages s WHERE s.product_id = p.id), '[]'::jsonb),
    'edges', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
      FROM public.product_schedule_dependencies e WHERE e.product_id = p.id), '[]'::jsonb),
    'revisions', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.id)
      FROM public.initial_schedule_revisions r WHERE r.product_id = p.id), '[]'::jsonb),
    'operations', COALESCE((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.schedule_version)
      FROM public.product_schedule_operations o WHERE o.product_id = p.id), '[]'::jsonb),
    'cursor', (SELECT to_jsonb(s) FROM public.product_schedule_state s WHERE s.product_id = p.id),
    'audit', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.event_id)
      FROM public.product_schedule_operation_events e WHERE e.product_id = p.id), '[]'::jsonb)
  ) AS state
  FROM sources JOIN public.products p ON p.id = sources.id
)
SELECT 'SOURCE_FINGERPRINT' AS record_type, id::text AS source_id, md5(state::text) AS fingerprint
FROM source_state ORDER BY id;

-- Save and pass this immutable baseline to the owner postflight.
SELECT 'HISTORICAL_R00_BASELINE' AS record_type, count(*)::text AS historical_r00_count,
  md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    AS historical_r00_fingerprint
FROM public.initial_schedule_revisions AS revision
WHERE revision.workspace_id <> :'workspace'::uuid;

-- Save the selected root-to-root edge endpoint IDs for the incomplete-remap rollback probe.
SELECT 'ROOT_EDGE' AS record_type, e.predecessor_activity_id::text AS root_predecessor,
  e.successor_activity_id::text AS root_successor
FROM public.product_schedule_dependencies e
JOIN public.stage_activities predecessor ON predecessor.id = e.predecessor_activity_id
  AND predecessor.stage_id IS NULL AND predecessor.discipline_id IS NULL AND predecessor.deleted_at IS NULL
JOIN public.stage_activities successor ON successor.id = e.successor_activity_id
  AND successor.stage_id IS NULL AND successor.discipline_id IS NULL AND successor.deleted_at IS NULL
WHERE e.workspace_id = :'workspace'::uuid AND e.product_id = :'vigente_source'::uuid
  AND e.endpoint_kind = 'activity'
ORDER BY e.id LIMIT 1;
ROLLBACK;
