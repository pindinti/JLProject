BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.stage_date_changes') IS NOT NULL OR
     to_regprocedure('public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)') IS NOT NULL OR
     to_regprocedure('public.create_discipline_stage_with_dates(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,date,date,text)') IS NOT NULL OR
     to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL OR
     to_regprocedure('public.create_discipline_stage(uuid,uuid,uuid,uuid,text,text,text,integer)') IS NULL OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin
       AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option)
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') OR
     EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.discipline_stages'::regclass
       AND attname IN ('planned_start', 'planned_end') AND NOT attisdropped) OR
     EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.discipline_stages'::regclass
       AND conname = 'discipline_stages_product_scope_id_unique') OR
     to_regclass('public.hierarchy_movement_events') IS NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     position('public.stage_date_changes' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) > 0 OR
     NOT has_table_privilege('jlproject_worker', 'public.discipline_stages', 'INSERT') THEN
    RAISE EXCEPTION 'Stage date migration prerequisites differ from the reviewed Development schema through migration 0027.';
  END IF;
END;
$$;

-- The history FK uses stable product scope because a hierarchy move changes the
-- stage's current discipline while audit rows retain the discipline at edit time.
ALTER TABLE public.discipline_stages
  ADD COLUMN planned_start date,
  ADD COLUMN planned_end date,
  ADD CONSTRAINT discipline_stages_planned_dates_check CHECK (
    planned_start IS NULL OR planned_end IS NULL OR planned_start <= planned_end
  ),
  ADD CONSTRAINT discipline_stages_product_scope_id_unique UNIQUE (workspace_id, product_id, id);

CREATE TABLE public.stage_date_changes (
  operation_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  stage_id uuid NOT NULL,
  discipline_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  previous_start date,
  previous_end date,
  new_start date,
  new_end date,
  reason text NOT NULL CHECK (
    char_length(reason) BETWEEN 10 AND 2000 AND reason = btrim(reason) AND reason !~ '[[:cntrl:]]'
  ),
  version_before bigint NOT NULL CHECK (version_before > 0),
  version_after bigint NOT NULL CHECK (version_after = version_before + 1),
  CONSTRAINT stage_date_changes_scope_fk FOREIGN KEY (workspace_id, product_id, stage_id)
    REFERENCES public.discipline_stages(workspace_id, product_id, id) ON DELETE RESTRICT,
  CONSTRAINT stage_date_changes_actor_fk FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT,
  CONSTRAINT stage_date_changes_previous_range_check CHECK (
    previous_start IS NULL OR previous_end IS NULL OR previous_start <= previous_end
  ),
  CONSTRAINT stage_date_changes_new_range_check CHECK (
    new_start IS NULL OR new_end IS NULL OR new_start <= new_end
  ),
  CONSTRAINT stage_date_changes_actual_change_check CHECK (
    previous_start IS DISTINCT FROM new_start OR previous_end IS DISTINCT FROM new_end
  ),
  CONSTRAINT stage_date_changes_stage_version_unique UNIQUE (stage_id, version_after)
);
CREATE INDEX stage_date_changes_history_idx
  ON public.stage_date_changes (workspace_id, product_id, changed_at DESC, operation_id DESC);
REVOKE ALL ON public.stage_date_changes FROM PUBLIC, jlproject_worker;

CREATE FUNCTION public.prevent_stage_date_change_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Stage date history is append-only.' USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_stage_date_change_mutation() FROM PUBLIC;
CREATE TRIGGER stage_date_changes_append_only
  BEFORE UPDATE OR DELETE ON public.stage_date_changes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_stage_date_change_mutation();

CREATE FUNCTION public.guard_discipline_stage_date_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_operation text;
  v_reason text;
  v_actor text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.planned_start IS NULL AND NEW.planned_end IS NULL THEN RETURN NEW; END IF;
    RAISE EXCEPTION 'Stage dates must be created through the audited operation.' USING ERRCODE = '23514';
  END IF;

  IF NEW.planned_start IS NOT DISTINCT FROM OLD.planned_start AND
     NEW.planned_end IS NOT DISTINCT FROM OLD.planned_end THEN
    RETURN NEW;
  END IF;
  IF current_user <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'An audited stage date operation is required.' USING ERRCODE = '23514';
  END IF;

  v_operation := NULLIF(current_setting('jlproject.stage_date_operation_id', true), '');
  v_reason := NULLIF(current_setting('jlproject.stage_date_reason', true), '');
  v_actor := NULLIF(current_setting('jlproject.stage_date_actor_id', true), '');
  IF v_operation IS NULL OR v_reason IS NULL OR v_actor IS NULL OR
     NEW.updated_by::text <> v_actor OR NEW.version <> OLD.version + 1 OR
     char_length(v_reason) NOT BETWEEN 10 AND 2000 OR v_reason <> btrim(v_reason) OR
     v_reason ~ '[[:cntrl:]]' OR
     (NEW.planned_start IS NOT NULL AND NEW.planned_end IS NOT NULL AND
       NEW.planned_start > NEW.planned_end) THEN
    RAISE EXCEPTION 'An audited stage date operation is required.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.stage_date_changes (
    operation_id, workspace_id, product_id, stage_id, discipline_id, actor_id,
    previous_start, previous_end, new_start, new_end, reason, version_before, version_after
  ) VALUES (
    v_operation::uuid, OLD.workspace_id, OLD.product_id, OLD.id, OLD.discipline_id, v_actor::uuid,
    OLD.planned_start, OLD.planned_end, NEW.planned_start, NEW.planned_end,
    v_reason, OLD.version, NEW.version
  );
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_discipline_stage_date_update() FROM PUBLIC;
CREATE TRIGGER discipline_stages_dates_audited
  BEFORE INSERT OR UPDATE ON public.discipline_stages
  FOR EACH ROW EXECUTE FUNCTION public.guard_discipline_stage_date_update();

CREATE FUNCTION public.change_discipline_stage_dates(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_actor_id uuid, p_operation_id uuid, p_start date, p_end date, p_reason text,
  p_expected_version bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_stage record;
  v_reason text;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_discipline_id IS NULL OR
     p_stage_id IS NULL OR p_actor_id IS NULL OR p_operation_id IS NULL OR
     p_expected_version IS NULL OR p_expected_version < 1 OR
     (p_start IS NOT NULL AND p_end IS NOT NULL AND p_start > p_end) THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;

  SELECT stage.id, stage.version, stage.planned_start, stage.planned_end
    INTO v_stage
    FROM public.discipline_stages AS stage
    JOIN public.products AS product ON product.workspace_id = stage.workspace_id
      AND product.id = stage.product_id
    WHERE stage.workspace_id = p_workspace_id AND stage.product_id = p_product_id
      AND stage.discipline_id = p_discipline_id AND stage.id = p_stage_id
      AND stage.deleted_at IS NULL AND product.active = true
    FOR UPDATE OF stage;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_stage.version <> p_expected_version THEN RETURN jsonb_build_object('status', 'stale'); END IF;
  IF v_stage.planned_start IS NOT DISTINCT FROM p_start AND
     v_stage.planned_end IS NOT DISTINCT FROM p_end THEN
    RETURN jsonb_build_object('status', 'unchanged');
  END IF;

  v_reason := btrim(p_reason);
  IF v_reason IS NULL OR char_length(v_reason) NOT BETWEEN 10 AND 2000 OR
     v_reason ~ '[[:cntrl:]]' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM set_config('jlproject.stage_date_operation_id', p_operation_id::text, true);
  PERFORM set_config('jlproject.stage_date_reason', v_reason, true);
  PERFORM set_config('jlproject.stage_date_actor_id', p_actor_id::text, true);
  UPDATE public.discipline_stages
    SET planned_start = p_start, planned_end = p_end, version = version + 1,
      updated_by = p_actor_id, updated_at = clock_timestamp()
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND id = p_stage_id;
  RETURN jsonb_build_object('status', 'updated');
END;
$$;
REVOKE ALL ON FUNCTION public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint) FROM PUBLIC;

CREATE FUNCTION public.create_discipline_stage_with_dates(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_actor_id uuid,
  p_operation_id uuid, p_code text, p_color text, p_display_name text,
  p_display_order integer, p_start date, p_end date, p_reason text
) RETURNS text
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_stage_id text;
  v_change jsonb;
BEGIN
  IF p_operation_id IS NULL OR (p_start IS NULL AND p_end IS NULL) OR
     (p_start IS NOT NULL AND p_end IS NOT NULL AND p_start > p_end) OR
     p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 10 AND 2000 OR
     p_reason ~ '[[:cntrl:]]' THEN
    RETURN 'invalid';
  END IF;

  v_stage_id := public.create_discipline_stage(
    p_workspace_id, p_product_id, p_discipline_id, p_actor_id,
    p_code, p_color, p_display_name, p_display_order);
  IF v_stage_id IN ('duplicate', 'conflict', 'not_found') THEN RETURN v_stage_id; END IF;
  IF v_stage_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RAISE EXCEPTION 'Stage creation returned an unexpected result.';
  END IF;

  v_change := public.change_discipline_stage_dates(
    p_workspace_id, p_product_id, p_discipline_id, v_stage_id::uuid, p_actor_id,
    p_operation_id, p_start, p_end, p_reason, 1);
  IF v_change->>'status' <> 'updated' THEN
    RAISE EXCEPTION 'Audited stage date creation failed.' USING ERRCODE = 'P0001';
  END IF;
  RETURN v_stage_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_discipline_stage_with_dates(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,date,date,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_discipline_stage_with_dates(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,date,date,text)
  TO jlproject_worker;

-- Transfer only the immutable ledger and audited operation code to the existing
-- no-login executor. The Worker receives EXECUTE access, not ledger DML access.
GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
-- Ownership transfers and the history-function replacement require the target
-- executor to have CREATE on this schema. Keep this grant only through that replacement.
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
ALTER TABLE public.stage_date_changes OWNER TO jlproject_date_executor;
ALTER FUNCTION public.prevent_stage_date_change_mutation() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.guard_discipline_stage_date_update() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)
  OWNER TO jlproject_date_executor;

GRANT UPDATE (planned_start, planned_end, version, updated_by, updated_at)
  ON public.discipline_stages TO jlproject_date_executor;
GRANT SELECT (id, workspace_id, product_id, discipline_id, display_name, deleted_at,
  version, planned_start, planned_end) ON public.discipline_stages TO jlproject_date_executor;
GRANT SELECT (id, workspace_id, product_id, name)
  ON public.product_disciplines TO jlproject_date_executor;

SET ROLE jlproject_date_executor;
GRANT EXECUTE ON FUNCTION public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)
  TO jlproject_worker;

DO $$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure);
  v_anchor constant text := '  ), eligible AS MATERIALIZED (';
  v_stage_event constant text := $stage$
    UNION ALL

    SELECT 'stage-date:' || change.operation_id::text, change.changed_at, change.actor_id,
      'stage_dates_changed',
      jsonb_build_object('kind', 'stage', 'id', stage.id::text, 'name', stage.display_name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name)),
      change.reason,
      jsonb_build_object('plannedStart', to_char(change.previous_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(change.previous_end, 'YYYY-MM-DD')),
      jsonb_build_object('plannedStart', to_char(change.new_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(change.new_end, 'YYYY-MM-DD')),
      '[]'::jsonb
    FROM public.stage_date_changes AS change
    JOIN public.discipline_stages AS stage ON stage.workspace_id = change.workspace_id
      AND stage.product_id = change.product_id AND stage.id = change.stage_id
    LEFT JOIN public.product_disciplines AS discipline ON discipline.workspace_id = change.workspace_id
      AND discipline.product_id = change.product_id AND discipline.id = change.discipline_id
    WHERE change.workspace_id = p_workspace_id AND change.product_id = p_product_id
$stage$;
  v_replaced text;
BEGIN
  IF position('public.stage_date_changes' IN v_definition) > 0 OR
     position(v_anchor IN v_definition) = 0 OR
     length(v_definition) - length(replace(v_definition, v_anchor, '')) <> length(v_anchor) THEN
    RAISE EXCEPTION 'Product history function source differs from the reviewed migration 0027 definition.';
  END IF;
  v_replaced := replace(v_definition, v_anchor, v_stage_event || v_anchor);
  EXECUTE v_replaced;
END;
$$;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.clone_product(uuid,uuid,uuid,text)'::regprocedure);
  v_declare_anchor constant text := '  v_target_id uuid;';
  v_insert_anchor constant text := $anchor$
      RETURNING id INTO v_stage_id;
      v_activities := '[]'::jsonb;
$anchor$;
  v_stage_json_anchor constant text := $anchor$
        'displayName', v_stage.display_name, 'displayOrder', v_stage.display_order,
        'activities', v_activities));
$anchor$;
  v_snapshot_anchor constant text := $anchor$
        'code', definition.code, 'displayName', stage.display_name)
$anchor$;
  v_declare_insert constant text := E'  v_target_id uuid;\n  v_stage_date_result jsonb;\n  v_stage_date_operation_id uuid;';
  v_insert_replacement constant text := $replacement$
      RETURNING id INTO v_stage_id;
      IF v_stage.planned_start IS NOT NULL OR v_stage.planned_end IS NOT NULL THEN
        v_stage_date_operation_id := gen_random_uuid();
        v_stage_date_result := public.change_discipline_stage_dates(
          p_workspace_id, v_product_id, v_discipline_id, v_stage_id, p_actor_id,
          v_stage_date_operation_id, v_stage.planned_start, v_stage.planned_end,
          format('Copied from product %s during cloning.', p_source_product_id), 1);
        IF v_stage_date_result->>'status' <> 'updated' THEN
          RAISE EXCEPTION 'Product clone stage date copy failed.' USING ERRCODE = 'P0001';
        END IF;
      END IF;
      v_activities := '[]'::jsonb;
$replacement$;
  v_stage_json_replacement constant text := $replacement$
        'displayName', v_stage.display_name, 'displayOrder', v_stage.display_order,
        'plannedStart', v_stage.planned_start, 'plannedEnd', v_stage.planned_end,
        'activities', v_activities));
$replacement$;
  v_snapshot_replacement constant text := $replacement$
        'code', definition.code, 'displayName', stage.display_name,
        'plannedStart', stage.planned_start, 'plannedEnd', stage.planned_end)
$replacement$;
  v_updated text;
BEGIN
  IF current_user <> 'neondb_owner' OR
     position('public.change_discipline_stage_dates' IN v_definition) > 0 OR
     position(v_declare_anchor IN v_definition) = 0 OR
     position(v_insert_anchor IN v_definition) = 0 OR
     position(v_stage_json_anchor IN v_definition) = 0 OR
     position(v_snapshot_anchor IN v_definition) = 0 OR
     length(v_definition) - length(replace(v_definition, v_declare_anchor, '')) <> length(v_declare_anchor) OR
     length(v_definition) - length(replace(v_definition, v_insert_anchor, '')) <> length(v_insert_anchor) OR
     length(v_definition) - length(replace(v_definition, v_stage_json_anchor, '')) <> length(v_stage_json_anchor) OR
     length(v_definition) - length(replace(v_definition, v_snapshot_anchor, '')) <> length(v_snapshot_anchor) THEN
    RAISE EXCEPTION 'Product clone function source differs from the reviewed migration 0012 definition.';
  END IF;
  v_updated := replace(v_definition, v_declare_anchor, v_declare_insert);
  v_updated := replace(v_updated, v_insert_anchor, v_insert_replacement);
  v_updated := replace(v_updated, v_stage_json_anchor, v_stage_json_replacement);
  v_updated := replace(v_updated, v_snapshot_anchor, v_snapshot_replacement);
  EXECUTE v_updated;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.discipline_stages'::regclass
       AND attname = 'planned_start' AND NOT attisdropped AND NOT attnotnull) OR
     NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.discipline_stages'::regclass
       AND attname = 'planned_end' AND NOT attisdropped AND NOT attnotnull) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.discipline_stages'::regclass
       AND conname = 'discipline_stages_planned_dates_check' AND contype = 'c') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.discipline_stages'::regclass
       AND conname = 'discipline_stages_product_scope_id_unique' AND contype = 'u') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.discipline_stages'::regclass
       AND tgname = 'discipline_stages_dates_audited' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_date_changes'::regclass
       AND tgname = 'stage_date_changes_append_only' AND tgenabled IN ('O', 'A')) OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.stage_date_changes'::regclass)
       <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'planned_start', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'planned_end', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'name', 'SELECT') OR
     NOT has_function_privilege('jlproject_worker',
       'public.create_discipline_stage_with_dates(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,date,date,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)', 'EXECUTE') OR
     position('public.stage_date_changes' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 OR
     has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'DELETE') OR
     has_table_privilege('jlproject_worker', 'public.stage_date_changes', 'TRUNCATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'planned_end', 'UPDATE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option)
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') OR
     position('public.change_discipline_stage_dates' IN pg_get_functiondef(
       'public.clone_product(uuid,uuid,uuid,text)'::regprocedure)) = 0 OR
     position('plannedStart' IN pg_get_functiondef(
       'public.clone_product(uuid,uuid,uuid,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Stage date migration postconditions or least-privilege boundaries are incorrect.';
  END IF;
END;
$$;

COMMIT;
