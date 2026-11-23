BEGIN;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $preflight$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regprocedure('public.guard_schedule_deletion_dependencies(uuid,uuid,jsonb)') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.initial_schedule_revisions'::regclass
         AND conname = 'initial_schedule_revisions_snapshot_check' AND convalidated
         AND pg_get_constraintdef(oid) LIKE '%(snapshot -> %dependencies% = %[]%') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.initial_schedule_revisions'::regclass
         AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.clone_product(uuid,uuid,uuid,text)'::regprocedure
       AND NOT prosecdef AND pg_get_userbyid(proowner) = 'neondb_owner') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Clone dependency migration prerequisites differ from the reviewed schema.';
  END IF;
END;
$preflight$;

ALTER TABLE public.initial_schedule_revisions
  DROP CONSTRAINT initial_schedule_revisions_snapshot_check,
  ADD CONSTRAINT initial_schedule_revisions_snapshot_check CHECK (
    jsonb_typeof(snapshot) = 'object' AND snapshot ? 'dependencies' AND
    jsonb_typeof(snapshot->'dependencies') = 'array' AND
    (import_batch_id IS NULL OR snapshot->'dependencies' = '[]'::jsonb));

GRANT INSERT (workspace_id, product_id, import_batch_id, snapshot, created_by),
  SELECT (id, workspace_id, product_id) ON public.initial_schedule_revisions TO jlproject_date_executor;
GRANT TRIGGER ON public.initial_schedule_revisions TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner
  WITH ADMIN FALSE, INHERIT FALSE, SET TRUE GRANTED BY neondb_owner;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;

-- Invoker identity is deliberate. Direct Worker inserts retain the empty graph contract.
CREATE FUNCTION public.guard_initial_revision_dependency_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NEW.snapshot->'dependencies' <> '[]'::jsonb AND current_user <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'A baseline with dependencies requires the controlled clone path.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.clone_schedule_dependencies(
  p_workspace uuid, p_source uuid, p_target uuid, p_actor uuid,
  p_stage_map jsonb, p_activity_map jsonb, p_snapshot jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_expected bigint;
  v_graph jsonb;
  v_edge jsonb;
  v_operation uuid;
  v_revision uuid;
  v_reason text := format('Copied dependencies from product %s during cloning.', p_source);
BEGIN
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Clone workspace is unavailable.' USING ERRCODE = '42501'; END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace AND auth_user_id = p_actor
      AND active AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Clone actor is not an editor.' USING ERRCODE = '42501'; END IF;
  PERFORM 1 FROM public.products WHERE workspace_id = p_workspace AND id = p_source FOR UPDATE;
  IF NOT FOUND OR p_source = p_target THEN
    RAISE EXCEPTION 'Dependency clone source is outside the permitted scope.' USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM public.products WHERE workspace_id = p_workspace AND id = p_target AND active
    AND planning_classification = 'em_estudo' AND created_by = p_actor
    AND xmin::text::bigint = txid_current() % 4294967296 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dependency clone target is not fresh.' USING ERRCODE = '42501'; END IF;

  SELECT count(*) INTO v_expected FROM public.product_schedule_dependencies
  WHERE workspace_id = p_workspace AND product_id = p_source;
  IF v_expected = 0 THEN RETURN NULL; END IF;

  IF p_snapshot#>>'{product,id}' IS DISTINCT FROM p_target::text OR
     p_snapshot->'dependencies' IS DISTINCT FROM '[]'::jsonb OR
     EXISTS (SELECT 1 FROM public.initial_schedule_revisions
       WHERE workspace_id = p_workspace AND product_id = p_target) OR
     EXISTS (SELECT 1 FROM public.product_schedule_dependencies
       WHERE workspace_id = p_workspace AND product_id = p_target) THEN
    RAISE EXCEPTION 'Dependency clone requires a fresh target and an initial snapshot.' USING ERRCODE = '23514';
  END IF;

  WITH snapshot_stages AS MATERIALIZED (
    SELECT stage.value AS entry
    FROM jsonb_array_elements(p_snapshot->'disciplines') AS discipline
    CROSS JOIN LATERAL jsonb_array_elements(discipline.value->'stages') AS stage
  ), snapshot_activities AS (
    SELECT value AS entry FROM jsonb_array_elements(p_snapshot->'rootActivities')
    UNION ALL
    SELECT activity.value FROM snapshot_stages
    CROSS JOIN LATERAL jsonb_array_elements(entry->'activities') AS activity
  ), mapped AS (
    SELECT 'stage' AS kind, mapping.key::uuid AS source_id, target.id AS target_id
    FROM jsonb_each_text(p_stage_map) AS mapping
    JOIN public.discipline_stages AS source ON source.id = mapping.key::uuid
      AND source.workspace_id = p_workspace AND source.product_id = p_source AND source.deleted_at IS NULL
    JOIN public.discipline_stages AS target ON target.id = mapping.value::uuid
      AND target.workspace_id = p_workspace AND target.product_id = p_target AND target.deleted_at IS NULL
      AND target.xmin::text::bigint = txid_current() % 4294967296
      AND target.definition_id = source.definition_id AND target.display_name = source.display_name
      AND target.planned_start IS NOT DISTINCT FROM source.planned_start
      AND target.planned_end IS NOT DISTINCT FROM source.planned_end
    WHERE EXISTS (SELECT 1 FROM snapshot_stages WHERE entry->>'id' = target.id::text)
    UNION ALL
    SELECT 'activity', mapping.key::uuid, target.id
    FROM jsonb_each_text(p_activity_map) AS mapping
    JOIN public.stage_activities AS source ON source.id = mapping.key::uuid
      AND source.workspace_id = p_workspace AND source.product_id = p_source AND source.deleted_at IS NULL
    JOIN public.stage_activities AS target ON target.id = mapping.value::uuid
      AND target.workspace_id = p_workspace AND target.product_id = p_target AND target.deleted_at IS NULL
      AND target.xmin::text::bigint = txid_current() % 4294967296
      AND target.name = source.name
      AND target.stage_id::text IS NOT DISTINCT FROM (p_stage_map->>source.stage_id::text)
      AND (source.stage_id IS NULL OR p_stage_map ? source.stage_id::text)
      AND target.planned_start IS NOT DISTINCT FROM source.planned_start
      AND target.planned_end IS NOT DISTINCT FROM source.planned_end
      AND target.planning_mode = source.planning_mode
      AND target.working_day_duration IS NOT DISTINCT FROM source.working_day_duration
      AND target.planning_calendar_version IS NOT DISTINCT FROM source.planning_calendar_version
    WHERE EXISTS (SELECT 1 FROM snapshot_activities WHERE entry->>'id' = target.id::text)
  ), unique_map AS MATERIALIZED (
    SELECT kind, source_id, target_id
    FROM (
      SELECT mapped.*, count(*) OVER (PARTITION BY kind, source_id) AS source_count,
        count(*) OVER (PARTITION BY kind, target_id) AS target_count
      FROM mapped
    ) AS counted WHERE source_count = 1 AND target_count = 1
  ), copied AS (
    INSERT INTO public.product_schedule_dependencies
      (workspace_id, product_id, endpoint_kind, predecessor_activity_id, successor_activity_id,
       predecessor_stage_id, successor_stage_id)
    SELECT p_workspace, p_target, edge.endpoint_kind,
      CASE WHEN edge.endpoint_kind = 'activity' THEN predecessor.target_id END,
      CASE WHEN edge.endpoint_kind = 'activity' THEN successor.target_id END,
      CASE WHEN edge.endpoint_kind = 'stage' THEN predecessor.target_id END,
      CASE WHEN edge.endpoint_kind = 'stage' THEN successor.target_id END
    FROM public.product_schedule_dependencies AS edge
    JOIN unique_map AS predecessor ON predecessor.kind = edge.endpoint_kind
      AND predecessor.source_id = COALESCE(edge.predecessor_activity_id, edge.predecessor_stage_id)
    JOIN unique_map AS successor ON successor.kind = edge.endpoint_kind
      AND successor.source_id = COALESCE(edge.successor_activity_id, edge.successor_stage_id)
    WHERE edge.workspace_id = p_workspace AND edge.product_id = p_source
    RETURNING *
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'kind', endpoint_kind,
    'predecessorId', COALESCE(predecessor_activity_id, predecessor_stage_id),
    'successorId', COALESCE(successor_activity_id, successor_stage_id)) ORDER BY id), '[]'::jsonb)
  INTO v_graph FROM copied;
  IF jsonb_array_length(v_graph) <> v_expected THEN
    RAISE EXCEPTION 'A dependency endpoint could not be remapped.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.initial_schedule_revisions (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (p_workspace, p_target, NULL, jsonb_set(p_snapshot, '{dependencies}', v_graph), p_actor)
  RETURNING id INTO v_revision;

  SELECT operation_id INTO v_operation FROM public.product_schedule_operations
  WHERE workspace_id = p_workspace AND product_id = p_target AND transaction_id = pg_current_xact_id();
  FOR v_edge IN SELECT value FROM jsonb_array_elements(v_graph) LOOP
    PERFORM public.write_product_schedule_operation_event(p_workspace, p_target, p_actor, v_operation,
      'product_cloned', v_reason, NULL, 'product_schedule_dependencies', (v_edge->>'id')::uuid,
      'dependency_added', NULL, NULL, NULL, v_edge);
  END LOOP;
  RETURN v_revision;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_initial_revision_dependency_insert(),
  public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb) TO jlproject_worker;

-- Install the insert gate without replacing the existing immutability trigger.
CREATE TRIGGER initial_schedule_revisions_dependency_insert
  BEFORE INSERT ON public.initial_schedule_revisions FOR EACH ROW
  EXECUTE FUNCTION public.guard_initial_revision_dependency_insert();
RESET ROLE;
REVOKE TRIGGER ON public.initial_schedule_revisions FROM jlproject_date_executor;

REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $install$
DECLARE
  v_definition text := pg_get_functiondef('public.clone_product(uuid,uuid,uuid,text)'::regprocedure);
  v_anchors text[] := ARRAY[
    '  v_snapshot jsonb;',
    '      RETURNING id INTO v_stage_id;',
    'v_product_id, p_actor_id, v_activity.id, v_discipline_id, v_stage_id);',
    'v_product_id, p_actor_id, v_root_activity.id);',
    '  INSERT INTO public.initial_schedule_revisions',
    '  RETURNING id INTO v_revision_id;',
    '  IF NOT FOUND THEN RETURN jsonb_build_object(''status'', ''duplicate''); END IF;',
    '  RETURN jsonb_build_object(''status'', ''cloned'','
  ];
  v_anchor text;
BEGIN
  FOREACH v_anchor IN ARRAY v_anchors LOOP
    IF length(v_definition) - length(replace(v_definition, v_anchor, '')) <> length(v_anchor) THEN
      RAISE EXCEPTION 'Product clone differs from the reviewed definition.';
    END IF;
  END LOOP;
  IF position('AND product.active IN (true, false) FOR UPDATE' IN v_definition) = 0 OR
     position('public.workspaces WHERE id = p_workspace_id FOR UPDATE' IN v_definition) = 0 OR
     position('''planningClassification'', ''em_estudo''' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Product clone source locking or classification differs from the reviewed definition.';
  END IF;
  v_definition := replace(v_definition, v_anchors[1], v_anchors[1] || $maps$
  v_dependency_stage_map jsonb := '{}'::jsonb;
  v_dependency_activity_map jsonb := '{}'::jsonb;
  v_previous_operation text := current_setting('jlproject.schedule_operation_id', true);
  v_previous_stage_operation text := current_setting('jlproject.stage_date_operation_id', true);
  v_previous_stage_reason text := current_setting('jlproject.stage_date_reason', true);
  v_previous_stage_actor text := current_setting('jlproject.stage_date_actor_id', true);$maps$);
  -- Keep stage ledger IDs distinct while pinning all generic events to the product insert's operation.
  v_definition := replace(v_definition, v_anchors[7], v_anchors[7] || $audit$
  PERFORM set_config('jlproject.schedule_operation_id',
    COALESCE(NULLIF(v_previous_operation, ''), NULLIF(current_setting('jlproject.stage_date_operation_id', true), ''),
      NULLIF(current_setting('jlproject.date_operation_id', true), ''),
      NULLIF(current_setting('jlproject.target_operation_id', true), ''),
      NULLIF(current_setting('jlproject.hierarchy_operation_id', true), ''),
      md5(pg_current_xact_id()::text)), true);$audit$);
  v_definition := replace(v_definition, v_anchors[2], v_anchors[2] || $stage$
      v_dependency_stage_map := v_dependency_stage_map || jsonb_build_object(v_stage.id::text, v_stage_id);$stage$);
  v_definition := replace(v_definition, v_anchors[3], v_anchors[3] || $activity$
        v_dependency_activity_map := v_dependency_activity_map || jsonb_build_object(v_activity.id::text, v_activity_id);$activity$);
  v_definition := replace(v_definition, v_anchors[4], v_anchors[4] || $root$
    v_dependency_activity_map := v_dependency_activity_map || jsonb_build_object(v_root_activity.id::text, v_activity_id);$root$);
  v_definition := replace(v_definition, v_anchors[5], $baseline$
  v_revision_id := public.clone_schedule_dependencies(p_workspace_id, p_source_product_id,
    v_product_id, p_actor_id, v_dependency_stage_map, v_dependency_activity_map, v_snapshot);
  IF v_revision_id IS NULL THEN
    INSERT INTO public.initial_schedule_revisions$baseline$);
  v_definition := replace(v_definition, v_anchors[6], '    RETURNING id INTO v_revision_id;' || E'\n  END IF;');
  v_definition := replace(v_definition, v_anchors[8], $restore$
  PERFORM set_config('jlproject.schedule_operation_id', COALESCE(v_previous_operation, ''), true);
  PERFORM set_config('jlproject.stage_date_operation_id', COALESCE(v_previous_stage_operation, ''), true);
  PERFORM set_config('jlproject.stage_date_reason', COALESCE(v_previous_stage_reason, ''), true);
  PERFORM set_config('jlproject.stage_date_actor_id', COALESCE(v_previous_stage_actor, ''), true);
$restore$ || v_anchors[8]);
  EXECUTE v_definition;
END;
$install$;

DO $postflight$
BEGIN
  IF has_any_column_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'SELECT, INSERT, UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'DELETE, TRUNCATE') OR
     has_any_column_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE, TRUNCATE') OR
     has_table_privilege('jlproject_date_executor', 'public.initial_schedule_revisions', 'TRIGGER') OR
     EXISTS (SELECT 1 FROM pg_proc AS routine
       CROSS JOIN LATERAL aclexplode(COALESCE(routine.proacl, acldefault('f', routine.proowner))) AS acl
       WHERE routine.oid IN ('public.guard_initial_revision_dependency_insert()'::regprocedure,
         'public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)'::regprocedure)
         AND acl.grantee = 0 AND acl.privilege_type = 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)', 'EXECUTE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'Clone dependency privilege postconditions failed.';
  END IF;
END;
$postflight$;

COMMIT;
