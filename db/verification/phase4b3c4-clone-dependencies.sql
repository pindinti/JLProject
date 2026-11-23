-- Run directly as jlproject_worker in its own database session on an approved disposable child.
-- This fixture uses direct Worker authentication and does not read the private dependency table.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';
SELECT set_config('jlproject.test_clone_scope', jsonb_build_object('workspace', :'workspace',
  'editor', :'editor', 'viewer', :'viewer', 'otherWorkspace', :'other_workspace',
  'vigente', :'vigente_source', 'study', :'study_source', 'archived', :'archived_source',
  'empty', :'empty_source', 'missingName', :'missing_target_name',
  'rootPredecessor', :'root_edge_predecessor', 'rootSuccessor', :'root_edge_successor')::text, true);

DO $worker$
DECLARE
  v_scope jsonb := current_setting('jlproject.test_clone_scope')::jsonb;
  v_workspace uuid := (v_scope->>'workspace')::uuid;
  v_editor uuid := (v_scope->>'editor')::uuid;
  v_reply jsonb;
  v_source uuid;
  v_target uuid;
  v_pred uuid;
  v_succ uuid;
  v_revision uuid;
  v_error_state text;
  v_error text;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' OR
     session_user <> 'jlproject_worker' OR
     NOT has_function_privilege(current_user, 'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') OR
     NOT has_function_privilege(current_user,
       'public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)', 'EXECUTE') OR
     NOT has_function_privilege(current_user, 'public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') OR
     has_table_privilege(current_user, 'public.product_schedule_dependencies', 'SELECT') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = v_editor AND active AND role = 'admin') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships WHERE workspace_id = v_workspace
       AND auth_user_id = (v_scope->>'viewer')::uuid AND active AND role = 'viewer') OR
     NOT EXISTS (SELECT 1 FROM public.workspace_memberships
       WHERE workspace_id = (v_scope->>'otherWorkspace')::uuid AND auth_user_id = v_editor
         AND active AND role = 'editor') THEN
    RAISE EXCEPTION 'Expected a direct authenticated Worker session and preprovisioned clone memberships.';
  END IF;

  -- The API passes its authenticated actor ID; this direct Worker fixture supplies an existing
  -- actor and the database function independently checks that actor's active membership.
  v_reply := public.clone_product(v_workspace, (v_scope->>'archived')::uuid,
    (v_scope->>'viewer')::uuid, 'Viewer denied ' || gen_random_uuid());
  IF v_reply->>'status' IS DISTINCT FROM 'denied' THEN
    RAISE EXCEPTION 'Viewer clone was not denied: %', v_reply;
  END IF;
  v_reply := public.clone_product((v_scope->>'otherWorkspace')::uuid, (v_scope->>'archived')::uuid,
    v_editor, 'Wrong workspace ' || gen_random_uuid());
  IF v_reply->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'Cross-workspace source clone was not hidden: %', v_reply;
  END IF;

  v_reply := public.clone_product(v_workspace, (v_scope->>'vigente')::uuid, v_editor,
    'Dependency clone verification vigente ' || gen_random_uuid());
  IF v_reply->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Vigente clone failed: %', v_reply; END IF;
  RAISE NOTICE 'CLONE_RESULT|vigente|%|%', v_reply#>>'{product,id}', v_reply->>'revisionId';

  v_reply := public.clone_product(v_workspace, (v_scope->>'study')::uuid, v_editor,
    'Dependency clone verification study ' || gen_random_uuid());
  IF v_reply->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Em estudo clone failed: %', v_reply; END IF;
  RAISE NOTICE 'CLONE_RESULT|study|%|%', v_reply#>>'{product,id}', v_reply->>'revisionId';

  v_reply := public.clone_product(v_workspace, (v_scope->>'archived')::uuid, v_editor,
    'Dependency clone verification archived ' || gen_random_uuid());
  IF v_reply->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Archived clone failed: %', v_reply; END IF;
  RAISE NOTICE 'CLONE_RESULT|archived|%|%', v_reply#>>'{product,id}', v_reply->>'revisionId';

  v_reply := public.clone_product(v_workspace, (v_scope->>'empty')::uuid, v_editor,
    'Dependency clone verification empty ' || gen_random_uuid());
  IF v_reply->>'status' IS DISTINCT FROM 'cloned' THEN RAISE EXCEPTION 'Empty-graph clone failed: %', v_reply; END IF;
  RAISE NOTICE 'CLONE_RESULT|empty|%|%', v_reply#>>'{product,id}', v_reply->>'revisionId';

  -- Leave a synthetic target with two copied root activities, then prove the incomplete graph helper rolls back.
  INSERT INTO public.products (workspace_id, name, planning_classification, created_by, updated_by)
  VALUES (v_workspace, v_scope->>'missingName', 'em_estudo', v_editor, v_editor)
  RETURNING id INTO v_target;
  v_source := (v_scope->>'vigente')::uuid;
  v_pred := public.clone_root_activity(v_workspace, v_source, v_target, v_editor,
    (v_scope->>'rootPredecessor')::uuid);
  v_succ := public.clone_root_activity(v_workspace, v_source, v_target, v_editor,
    (v_scope->>'rootSuccessor')::uuid);
  BEGIN
    PERFORM public.clone_schedule_dependencies(v_workspace, v_source, v_target, v_editor,
      '{}'::jsonb,
      jsonb_build_object(v_scope->>'rootPredecessor', v_pred, v_scope->>'rootSuccessor', v_succ),
      jsonb_build_object('product', jsonb_build_object('id', v_target), 'dependencies', '[]'::jsonb,
        'disciplines', '[]'::jsonb,
        'rootActivities', jsonb_build_array(jsonb_build_object('id', v_pred), jsonb_build_object('id', v_succ))));
    RAISE EXCEPTION 'Expected an incomplete dependency remap to fail.';
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_error_state = RETURNED_SQLSTATE, v_error = MESSAGE_TEXT;
    IF v_error_state <> '23514' OR v_error <> 'A dependency endpoint could not be remapped.' THEN RAISE; END IF;
  END;

  -- This target has no baseline, so a duplicate key cannot mask the direct nonempty R00 insert guard.
  BEGIN
    INSERT INTO public.initial_schedule_revisions (workspace_id, product_id, snapshot, created_by)
    VALUES (v_workspace, v_target, '{"dependencies":[{}]}', v_editor);
    RAISE EXCEPTION 'Expected direct nonempty R00 insert to fail.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'MISSING_REMAP_TARGET|%', v_target;
END;
$worker$;
COMMIT;
