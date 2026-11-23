-- Run in a separate read-only neondb_owner session after the direct Worker fixture commits.
-- Supply the source fingerprints, historical R00 baseline, clone product/R00 ID pairs, and failed-remap target ID.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.test_clone_postflight', jsonb_build_object(
  'workspace', :'workspace', 'editor', :'editor',
  'historicalR00Count', :'historical_r00_count',
  'historicalR00Fingerprint', :'historical_r00_fingerprint',
  'sources', jsonb_build_array(
    jsonb_build_object('id', :'vigente_source', 'fingerprint', :'vigente_fingerprint',
      'target', :'vigente_clone', 'revision', :'vigente_revision', 'status', 'vigente', 'linked', true),
    jsonb_build_object('id', :'study_source', 'fingerprint', :'study_fingerprint',
      'target', :'study_clone', 'revision', :'study_revision', 'status', 'em_estudo', 'linked', true),
    jsonb_build_object('id', :'archived_source', 'fingerprint', :'archived_fingerprint',
      'target', :'archived_clone', 'revision', :'archived_revision', 'status', 'arquivado', 'linked', true),
    jsonb_build_object('id', :'empty_source', 'fingerprint', :'empty_fingerprint',
      'target', :'empty_clone', 'revision', :'empty_revision', 'status', 'vigente', 'linked', false)),
  'missingTarget', :'missing_target_id')::text, true);

DO $owner_postflight$
DECLARE
  v_scope jsonb := current_setting('jlproject.test_clone_postflight')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_editor uuid := (v_scope->>'editor')::uuid;
  v_source record;
  v_graph jsonb;
  v_expected jsonb;
  v_target uuid;
  v_missing uuid := (v_scope->>'missingTarget')::uuid;
  v_fingerprint text;
  v_historical_count bigint;
  v_historical_fingerprint text;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION 'Postflight must use the separate authorized owner read session.';
  END IF;
  SELECT count(*)::bigint,
    md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    INTO v_historical_count, v_historical_fingerprint
  FROM public.initial_schedule_revisions AS revision WHERE revision.workspace_id <> v_workspace;
  IF v_historical_count <> (v_scope->>'historicalR00Count')::bigint OR
     v_historical_fingerprint IS DISTINCT FROM v_scope->>'historicalR00Fingerprint' OR
     (SELECT count(*) FROM public.initial_schedule_revisions) <> v_historical_count + 8 THEN
    RAISE EXCEPTION 'Historical R00 rows changed, or source/clone R00 counts differ from the expected fixture.';
  END IF;
  IF v_missing IS NULL OR NOT EXISTS (SELECT 1 FROM public.products
      WHERE workspace_id = v_workspace AND id = v_missing) THEN
    RAISE EXCEPTION 'Worker fixture did not identify its failed-remap target.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.product_schedule_dependencies WHERE product_id = v_missing) OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE product_id = v_missing) OR
     EXISTS (SELECT 1 FROM public.product_schedule_operation_events
       WHERE product_id = v_missing AND entity_type = 'product_schedule_dependencies') OR
     (SELECT count(*) FROM public.product_schedule_operations WHERE product_id = v_missing) <> 1 OR
     (SELECT schedule_version FROM public.product_schedule_state WHERE product_id = v_missing) <> 1 OR
     (SELECT count(*) FROM public.stage_activities WHERE product_id = v_missing
       AND discipline_id IS NULL AND stage_id IS NULL AND deleted_at IS NULL) <> 2 THEN
    RAISE EXCEPTION 'Failed dependency copy left graph, R00, audit residue, or an incomplete setup.';
  END IF;

  FOR v_source IN SELECT value FROM jsonb_array_elements(v_scope->'sources') AS sources(value) LOOP
    -- Recompute the full source state so product, hierarchy, dates, graph, R00 and audit immutability are checked.
    SELECT md5(jsonb_build_object(
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
    )::text) INTO v_fingerprint
    FROM public.products p WHERE p.workspace_id = v_workspace AND p.id = (v_source.value->>'id')::uuid;
    IF v_fingerprint IS DISTINCT FROM v_source.value->>'fingerprint' THEN
      RAISE EXCEPTION 'Clone changed source product %, its schedule, graph, R00 or audit.', v_source.value->>'id';
    END IF;

    v_target := (v_source.value->>'target')::uuid;
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace AND id = v_target
        AND active AND planning_classification = 'em_estudo') OR
       NOT EXISTS (SELECT 1 FROM public.products WHERE workspace_id = v_workspace
        AND id = (v_source.value->>'id')::uuid AND
        (CASE WHEN active THEN planning_classification ELSE 'arquivado' END) = v_source.value->>'status') OR
       NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions r WHERE r.workspace_id = v_workspace
        AND r.product_id = v_target AND r.id = (v_source.value->>'revision')::uuid
        AND r.label = 'R00' AND r.import_batch_id IS NULL) THEN
      RAISE EXCEPTION 'Clone target classification, source status, or R00 identity differed.';
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.endpoint_kind,
      'predecessorId', COALESCE(e.predecessor_activity_id, e.predecessor_stage_id),
      'successorId', COALESCE(e.successor_activity_id, e.successor_stage_id)) ORDER BY e.id), '[]'::jsonb)
    INTO v_graph FROM public.product_schedule_dependencies e
    WHERE e.workspace_id = v_workspace AND e.product_id = v_target;
    IF (SELECT snapshot->'dependencies' FROM public.initial_schedule_revisions
        WHERE id = (v_source.value->>'revision')::uuid) IS DISTINCT FROM v_graph THEN
      RAISE EXCEPTION 'New R00 dependency graph differs from the working graph.';
    END IF;

    IF (v_source.value->>'linked')::boolean AND EXISTS (
      SELECT 1 FROM public.product_schedule_dependencies source_edge
      JOIN public.stage_activities source_pred ON source_pred.id = source_edge.predecessor_activity_id
      JOIN public.stage_activities source_succ ON source_succ.id = source_edge.successor_activity_id
      WHERE source_edge.product_id = (v_source.value->>'id')::uuid
        AND source_edge.endpoint_kind = 'activity'
        AND source_pred.stage_id IS NULL AND source_pred.discipline_id IS NULL
        AND source_succ.stage_id IS NULL AND source_succ.discipline_id IS NULL
    ) AND NOT EXISTS (
      SELECT 1 FROM public.product_schedule_dependencies source_edge
      JOIN public.stage_activities source_pred ON source_pred.id = source_edge.predecessor_activity_id
      JOIN public.stage_activities source_succ ON source_succ.id = source_edge.successor_activity_id
      JOIN public.product_schedule_dependencies target_edge ON target_edge.product_id = v_target
      JOIN public.stage_activities target_pred ON target_pred.id = target_edge.predecessor_activity_id
      JOIN public.stage_activities target_succ ON target_succ.id = target_edge.successor_activity_id
      JOIN public.initial_schedule_revisions r ON r.id = (v_source.value->>'revision')::uuid
      WHERE source_edge.product_id = (v_source.value->>'id')::uuid
        AND source_edge.endpoint_kind = 'activity'
        AND source_pred.stage_id IS NULL AND source_pred.discipline_id IS NULL
        AND source_succ.stage_id IS NULL AND source_succ.discipline_id IS NULL
        AND target_pred.stage_id IS NULL AND target_pred.discipline_id IS NULL
        AND target_succ.stage_id IS NULL AND target_succ.discipline_id IS NULL
        AND target_pred.name = source_pred.name AND target_succ.name = source_succ.name
        AND r.snapshot->'rootActivities' @> jsonb_build_array(
          jsonb_build_object('id', target_pred.id), jsonb_build_object('id', target_succ.id))
    ) THEN
      RAISE EXCEPTION 'A linked source root edge did not reach the clone root schedule and R00.';
    END IF;

    WITH entities AS (
      SELECT id, product_id, 'stage' AS kind, display_name AS name, planned_start, planned_end
      FROM public.discipline_stages WHERE deleted_at IS NULL AND product_id IN ((v_source.value->>'id')::uuid, v_target)
      UNION ALL
      SELECT id, product_id, 'activity', name, planned_start, planned_end
      FROM public.stage_activities WHERE deleted_at IS NULL AND product_id IN ((v_source.value->>'id')::uuid, v_target)
    ), endpoint_map AS (
      SELECT source.id AS from_id, dest.id AS to_id, source.kind
      FROM entities source JOIN entities dest ON source.kind = dest.kind AND source.name = dest.name
        AND source.id <> dest.id AND source.planned_start IS NOT DISTINCT FROM dest.planned_start
        AND source.planned_end IS NOT DISTINCT FROM dest.planned_end
      WHERE source.product_id = (v_source.value->>'id')::uuid AND dest.product_id = v_target
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', e.endpoint_kind,
      'predecessorId', pred.to_id, 'successorId', succ.to_id)), '[]'::jsonb)
    INTO v_expected FROM public.product_schedule_dependencies e
    LEFT JOIN endpoint_map pred ON pred.kind = e.endpoint_kind
      AND pred.from_id = COALESCE(e.predecessor_activity_id, e.predecessor_stage_id)
    LEFT JOIN endpoint_map succ ON succ.kind = e.endpoint_kind
      AND succ.from_id = COALESCE(e.successor_activity_id, e.successor_stage_id)
    WHERE e.product_id = (v_source.value->>'id')::uuid;
    IF jsonb_array_length(v_graph) <> jsonb_array_length(v_expected) OR
       EXISTS (SELECT 1 FROM jsonb_array_elements(v_expected) expected(value)
         WHERE expected.value->>'predecessorId' IS NULL OR expected.value->>'successorId' IS NULL OR
           NOT v_graph @> jsonb_build_array(expected.value)) OR
       (v_source.value->>'linked')::boolean AND
         (jsonb_array_length(v_graph) < 3 OR NOT v_graph @> '[{"kind":"activity"}]' OR
           NOT v_graph @> '[{"kind":"stage"}]') OR
       NOT (v_source.value->>'linked')::boolean AND v_graph <> '[]'::jsonb OR
       EXISTS (SELECT 1 FROM public.product_schedule_dependencies source_edge
         JOIN public.product_schedule_dependencies target_edge ON source_edge.id = target_edge.id
         WHERE source_edge.product_id = (v_source.value->>'id')::uuid AND target_edge.product_id = v_target) THEN
      RAISE EXCEPTION 'Clone graph differs from its complete source endpoint remap.';
    END IF;

    IF (SELECT count(*) FROM public.product_schedule_operations WHERE product_id = v_target) <> 1 OR
       (SELECT schedule_version FROM public.product_schedule_state WHERE product_id = v_target) <> 1 OR
       (SELECT count(*) FROM public.product_schedule_operation_events WHERE product_id = v_target
         AND entity_type = 'product_schedule_dependencies' AND change_type = 'dependency_added')
         <> jsonb_array_length(v_graph) OR
       EXISTS (SELECT 1 FROM jsonb_array_elements(v_graph) edge(value) WHERE NOT EXISTS (
         SELECT 1 FROM public.product_schedule_operation_events event
         JOIN public.product_schedule_operations operation USING (workspace_id, product_id, schedule_version, operation_id)
         WHERE event.product_id = v_target AND event.entity_type = 'product_schedule_dependencies'
           AND event.entity_id::text = edge.value->>'id' AND event.new_values = edge.value
           AND operation.actor_id = v_editor)) THEN
      RAISE EXCEPTION 'Copied dependency events are not grouped in one clone operation.';
    END IF;
  END LOOP;
END;
$owner_postflight$;
ROLLBACK;
