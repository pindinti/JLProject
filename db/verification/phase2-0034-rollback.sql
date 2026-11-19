\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '2min';

DO $verification$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_source uuid;
  v_clone jsonb;
  v_source_status text;
  v_name text := 'P2 status source ' || gen_random_uuid()::text;
BEGIN
  SELECT workspace_id, auth_user_id INTO v_workspace, v_actor
    FROM public.workspace_memberships
    WHERE active AND role = 'admin'
    ORDER BY workspace_id, auth_user_id LIMIT 1;
  IF v_workspace IS NULL THEN
    RAISE EXCEPTION 'An active Development administrator is required.';
  END IF;
  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, v_name, v_actor, v_actor) RETURNING id INTO v_source;
  IF (SELECT planning_classification FROM public.products WHERE id = v_source) <> 'vigente' THEN
    RAISE EXCEPTION 'Ordinary product creation did not default to vigente.';
  END IF;
  SELECT public.clone_product(v_workspace, v_source, v_actor,
    'P2 status clone ' || gen_random_uuid()::text) INTO v_clone;
  IF v_clone->>'status' <> 'cloned' OR
     v_clone->'product'->>'planningClassification' <> 'em_estudo' OR
     NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions
       WHERE product_id = (v_clone->'product'->>'id')::uuid AND label = 'R00') THEN
    RAISE EXCEPTION 'Clone status or independent R00 verification failed.';
  END IF;
  IF (SELECT planning_classification FROM public.products WHERE id = v_source) <> 'vigente' THEN
    RAISE EXCEPTION 'Cloning changed the source product.';
  END IF;
  FOR v_source_status IN SELECT unnest(ARRAY['em_estudo', 'arquivado']) LOOP
    INSERT INTO public.products
      (workspace_id, name, active, planning_classification, created_by, updated_by)
      VALUES (v_workspace, v_name || ' ' || v_source_status,
        v_source_status <> 'arquivado', 'em_estudo', v_actor, v_actor)
      RETURNING id INTO v_source;
    SELECT public.clone_product(v_workspace, v_source, v_actor,
      'P2 clone from ' || v_source_status || ' ' || gen_random_uuid()::text) INTO v_clone;
    IF v_clone->>'status' <> 'cloned' OR
       v_clone->'product'->>'planningClassification' <> 'em_estudo' OR
       NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions
         WHERE product_id = (v_clone->'product'->>'id')::uuid AND label = 'R00') OR
       (SELECT active FROM public.products WHERE id = v_source) <> (v_source_status <> 'arquivado') THEN
      RAISE EXCEPTION 'Cloning from % failed or modified the source.', v_source_status;
    END IF;
  END LOOP;
  IF has_column_privilege('jlproject_worker', 'public.products', 'active', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.products', 'planning_classification', 'UPDATE') THEN
    RAISE EXCEPTION 'The Worker can bypass the controlled status operation.';
  END IF;
END;
$verification$;

ROLLBACK;
