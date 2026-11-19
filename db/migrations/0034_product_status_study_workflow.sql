BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR
     to_regclass('public.product_schedule_operations') IS NULL OR
     to_regprocedure('public.clone_product(uuid,uuid,uuid,text)') IS NULL OR
     to_regprocedure('public.capture_product_schedule_mutation()') IS NULL OR
     EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.products'::regclass
       AND attname = 'planning_classification' AND NOT attisdropped) OR
     to_regprocedure('public.change_product_status(uuid,uuid,uuid,text,bigint,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Product status migration prerequisites differ from the reviewed schema.';
  END IF;
END;
$$;

ALTER TABLE public.products
  ADD COLUMN planning_classification text NOT NULL DEFAULT 'vigente'
    CONSTRAINT products_planning_classification_check
      CHECK (planning_classification IN ('vigente', 'em_estudo'));

-- Keep archived rows inactive; the classification records their last active choice.
CREATE FUNCTION public.change_product_status(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid,
  p_status text, p_expected_version bigint, p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_product public.products%ROWTYPE;
  v_active boolean;
  v_classification text;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('vigente', 'em_estudo', 'arquivado') OR
     p_expected_version IS NULL OR p_expected_version < 1 OR
     p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 10 AND 2000 OR
     p_reason <> btrim(p_reason) OR p_reason ~ '[[:cntrl:]]' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'denied'); END IF;
  SELECT * INTO v_product FROM public.products
    WHERE workspace_id = p_workspace_id AND id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_product.version <> p_expected_version THEN
    RETURN jsonb_build_object('status', 'stale');
  END IF;
  v_active := p_status <> 'arquivado';
  v_classification := CASE WHEN v_active THEN p_status ELSE v_product.planning_classification END;
  IF v_product.active = v_active AND v_product.planning_classification = v_classification THEN
    RETURN jsonb_build_object('status', 'stale');
  END IF;
  PERFORM set_config('jlproject.schedule_actor_id', p_actor_id::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', gen_random_uuid()::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'product_status_changed', true);
  PERFORM set_config('jlproject.schedule_justification', p_reason, true);
  UPDATE public.products SET active = v_active,
      planning_classification = v_classification, version = version + 1,
      updated_by = p_actor_id, updated_at = now()
    WHERE workspace_id = p_workspace_id AND id = p_product_id
    RETURNING * INTO v_product;
  RETURN jsonb_build_object('status', 'updated', 'product', jsonb_build_object(
    'id', v_product.id, 'workspaceId', v_product.workspace_id,
    'name', v_product.name, 'description', v_product.description,
    'active', v_product.active, 'planningClassification', v_product.planning_classification,
    'version', v_product.version, 'createdAt', v_product.created_at,
    'updatedAt', v_product.updated_at));
END;
$$;
REVOKE ALL ON FUNCTION public.change_product_status(uuid,uuid,uuid,text,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_product_status(uuid,uuid,uuid,text,bigint,text) TO jlproject_worker;
REVOKE UPDATE (active) ON public.products FROM jlproject_worker;

DO $$
DECLARE
  v_definition text := pg_get_functiondef('public.clone_product(uuid,uuid,uuid,text)'::regprocedure);
  v_source_anchor constant text := 'AND product.active = true';
  v_insert_anchor constant text := 'INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)';
  v_values_anchor constant text := 'VALUES (p_workspace_id, p_name, v_source_product.description, p_actor_id, p_actor_id)';
  v_result_anchor constant text := '''active'', true,';
BEGIN
  IF position(v_source_anchor IN v_definition) = 0 OR
     position(v_insert_anchor IN v_definition) = 0 OR
     position(v_values_anchor IN v_definition) = 0 OR
     position(v_result_anchor IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Clone function differs from the reviewed source.';
  END IF;
  v_definition := replace(v_definition, v_source_anchor, 'AND product.active IN (true, false)');
  v_definition := replace(v_definition, v_insert_anchor,
    'INSERT INTO public.products (workspace_id, name, description, planning_classification, created_by, updated_by)');
  v_definition := replace(v_definition, v_values_anchor,
    'VALUES (p_workspace_id, p_name, v_source_product.description, ''em_estudo'', p_actor_id, p_actor_id)');
  v_definition := replace(v_definition, v_result_anchor,
    '''active'', true, ''planningClassification'', ''em_estudo'',');
  EXECUTE v_definition;
END;
$$;

DO $$
BEGIN
  IF has_column_privilege('jlproject_worker', 'public.products', 'active', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.products', 'planning_classification', 'UPDATE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.change_product_status(uuid,uuid,uuid,text,bigint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Product status privilege postconditions failed.';
  END IF;
END;
$$;

COMMIT;
