BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.product_schedule_state') IS NOT NULL OR
     to_regclass('public.product_schedule_operations') IS NOT NULL OR
     to_regclass('public.product_schedule_operation_events') IS NOT NULL OR
     to_regprocedure('public.capture_product_schedule_mutation()') IS NOT NULL OR
     to_regprocedure('public.read_product_schedule_cursor(uuid,uuid,uuid)') IS NOT NULL OR
     to_regprocedure('public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)') IS NOT NULL OR
     to_regprocedure('public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)') IS NOT NULL OR
     to_regclass('public.stage_date_changes') IS NULL OR
     to_regclass('public.activity_date_changes') IS NULL OR
     to_regclass('public.business_target_date_changes') IS NULL OR
     to_regclass('public.hierarchy_movement_events') IS NULL OR
     to_regclass('public.schedule_deletion_events') IS NULL OR
     to_regclass('public.calendar_reschedule_changes') IS NULL OR
     to_regclass('public.calendar_reschedule_reversals') IS NULL OR
     NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
       AND table_name = 'discipline_stages' AND column_name = 'planned_start') OR
     NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
       AND table_name = 'discipline_stages' AND column_name = 'planned_end') OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin
       AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     to_regprocedure('public.change_discipline_stage_dates(uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)') IS NULL THEN
    RAISE EXCEPTION 'Phase 1 migration prerequisites differ from the reviewed Development schema through migration 0028.';
  END IF;
END;
$$;

-- Block all existing schedule writers while establishing the initial cursor and
-- installing the row triggers. The transaction makes the cutover gap-free.
LOCK TABLE public.products, public.product_disciplines, public.discipline_stages,
  public.stage_activities, public.business_targets, public.stage_definitions
  IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE public.product_schedule_state (
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  schedule_version bigint NOT NULL DEFAULT 0 CHECK (schedule_version >= 0),
  history_watermark bigint NOT NULL DEFAULT 0 CHECK (history_watermark >= 0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, product_id),
  CONSTRAINT product_schedule_state_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT
);

CREATE TABLE public.product_schedule_operations (
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  schedule_version bigint NOT NULL CHECK (schedule_version > 0),
  operation_id uuid NOT NULL,
  transaction_id xid8 NOT NULL,
  actor_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  operation_type text NOT NULL CHECK (char_length(operation_type) BETWEEN 1 AND 80),
  justification text CHECK (justification IS NULL OR
    (char_length(justification) BETWEEN 10 AND 2000 AND justification = btrim(justification)
      AND justification !~ '[[:cntrl:]]')),
  reversal_of_operation_id uuid,
  PRIMARY KEY (workspace_id, product_id, schedule_version),
  CONSTRAINT product_schedule_operations_operation_unique UNIQUE (workspace_id, product_id, operation_id),
  CONSTRAINT product_schedule_operations_transaction_unique UNIQUE (workspace_id, product_id, transaction_id),
  CONSTRAINT product_schedule_operations_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT product_schedule_operations_actor_fk FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT
);
CREATE INDEX product_schedule_operations_history_idx
  ON public.product_schedule_operations (workspace_id, product_id, schedule_version DESC);

CREATE TABLE public.product_schedule_operation_events (
  event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  schedule_version bigint NOT NULL,
  operation_id uuid NOT NULL,
  entity_type text NOT NULL CHECK (char_length(entity_type) BETWEEN 1 AND 80),
  entity_id uuid NOT NULL,
  change_type text NOT NULL CHECK (char_length(change_type) BETWEEN 1 AND 80),
  parent_before jsonb NOT NULL DEFAULT '{}'::jsonb,
  parent_after jsonb NOT NULL DEFAULT '{}'::jsonb,
  previous_values jsonb NOT NULL DEFAULT '{}'::jsonb,
  new_values jsonb NOT NULL DEFAULT '{}'::jsonb,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT product_schedule_operation_events_operation_fk FOREIGN KEY
    (workspace_id, product_id, schedule_version)
    REFERENCES public.product_schedule_operations(workspace_id, product_id, schedule_version)
    ON DELETE RESTRICT,
  CONSTRAINT product_schedule_operation_events_event_unique UNIQUE
    (workspace_id, product_id, operation_id, event_id)
);
CREATE INDEX product_schedule_operation_events_product_idx
  ON public.product_schedule_operation_events (workspace_id, product_id, event_id);
CREATE INDEX product_schedule_operation_events_operation_idx
  ON public.product_schedule_operation_events (workspace_id, product_id, operation_id, event_id);

CREATE TABLE public.product_schedule_operation_links (
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  schedule_version bigint NOT NULL,
  operation_id uuid NOT NULL,
  source_ledger text NOT NULL CHECK (char_length(source_ledger) BETWEEN 1 AND 80),
  source_operation_id uuid NOT NULL,
  link_kind text NOT NULL DEFAULT 'audit_detail' CHECK (link_kind IN ('audit_detail', 'reversal_of')),
  linked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, product_id, schedule_version, source_ledger, source_operation_id),
  CONSTRAINT product_schedule_operation_links_operation_fk FOREIGN KEY
    (workspace_id, product_id, schedule_version)
    REFERENCES public.product_schedule_operations(workspace_id, product_id, schedule_version)
    ON DELETE RESTRICT
);

INSERT INTO public.product_schedule_state (workspace_id, product_id)
SELECT workspace_id, id FROM public.products;

CREATE FUNCTION public.prevent_product_schedule_audit_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Living Schedule audit records are append-only.' USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_product_schedule_audit_mutation() FROM PUBLIC;
CREATE TRIGGER product_schedule_operations_append_only
  BEFORE UPDATE OR DELETE ON public.product_schedule_operations
  FOR EACH ROW EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();
CREATE TRIGGER product_schedule_operations_no_truncate
  BEFORE TRUNCATE ON public.product_schedule_operations
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();
CREATE TRIGGER product_schedule_operation_events_append_only
  BEFORE UPDATE OR DELETE ON public.product_schedule_operation_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();
CREATE TRIGGER product_schedule_operation_events_no_truncate
  BEFORE TRUNCATE ON public.product_schedule_operation_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();
CREATE TRIGGER product_schedule_operation_links_append_only
  BEFORE UPDATE OR DELETE ON public.product_schedule_operation_links
  FOR EACH ROW EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();
CREATE TRIGGER product_schedule_operation_links_no_truncate
  BEFORE TRUNCATE ON public.product_schedule_operation_links
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();

CREATE FUNCTION public.write_product_schedule_operation_event(
  p_workspace_id uuid,
  p_product_id uuid,
  p_actor_id uuid,
  p_operation_id uuid,
  p_operation_type text,
  p_justification text,
  p_reversal_of uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_change_type text,
  p_parent_before jsonb,
  p_parent_after jsonb,
  p_previous_values jsonb,
  p_new_values jsonb
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_transaction_id xid8 := pg_current_xact_id();
  v_operation_id uuid;
  v_schedule_version bigint;
  v_existing_operation_id uuid;
  v_existing_actor_id uuid;
  v_event_id bigint;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_operation_type IS NULL OR char_length(p_operation_type) NOT BETWEEN 1 AND 80 OR
     p_entity_type IS NULL OR p_entity_id IS NULL OR p_change_type IS NULL THEN
    RAISE EXCEPTION 'A complete Living Schedule audit context is required.' USING ERRCODE = '23514';
  END IF;
  PERFORM 1 FROM public.workspace_memberships AS membership
    WHERE membership.workspace_id = p_workspace_id AND membership.auth_user_id = p_actor_id
      AND membership.active AND membership.role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The schedule actor is not an active workspace editor.' USING ERRCODE = '42501';
  END IF;

  v_operation_id := COALESCE(p_operation_id,
    md5(v_transaction_id::text)::uuid);
  SELECT operation.schedule_version, operation.operation_id, operation.actor_id
    INTO v_schedule_version, v_existing_operation_id, v_existing_actor_id
    FROM public.product_schedule_operations AS operation
    WHERE operation.workspace_id = p_workspace_id AND operation.product_id = p_product_id
      AND operation.transaction_id = v_transaction_id;
  IF FOUND THEN
    IF v_existing_operation_id <> v_operation_id OR v_existing_actor_id <> p_actor_id THEN
      RAISE EXCEPTION 'A product transaction cannot contain multiple Living Schedule operations.'
        USING ERRCODE = '23514';
    END IF;
  ELSE
    UPDATE public.product_schedule_state AS state
      SET schedule_version = state.schedule_version + 1, updated_at = clock_timestamp()
      WHERE state.workspace_id = p_workspace_id AND state.product_id = p_product_id
      RETURNING state.schedule_version INTO v_schedule_version;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Living Schedule state is missing for product %.', p_product_id
        USING ERRCODE = '23503';
    END IF;
    INSERT INTO public.product_schedule_operations (
      workspace_id, product_id, schedule_version, operation_id, transaction_id,
      actor_id, operation_type, justification, reversal_of_operation_id
    ) VALUES (
      p_workspace_id, p_product_id, v_schedule_version, v_operation_id, v_transaction_id,
      p_actor_id, p_operation_type, p_justification, p_reversal_of
    );
  END IF;

  INSERT INTO public.product_schedule_operation_events (
    workspace_id, product_id, schedule_version, operation_id, entity_type, entity_id,
    change_type, parent_before, parent_after, previous_values, new_values
  ) VALUES (
    p_workspace_id, p_product_id, v_schedule_version, v_operation_id, p_entity_type, p_entity_id,
    p_change_type, COALESCE(p_parent_before, '{}'::jsonb), COALESCE(p_parent_after, '{}'::jsonb),
    COALESCE(p_previous_values, '{}'::jsonb), COALESCE(p_new_values, '{}'::jsonb)
  ) RETURNING event_id INTO v_event_id;
  UPDATE public.product_schedule_state AS state
    SET history_watermark = GREATEST(state.history_watermark, v_event_id), updated_at = clock_timestamp()
    WHERE state.workspace_id = p_workspace_id AND state.product_id = p_product_id;

  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger, source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'activity_date_changes', audit.operation_id
    FROM public.activity_date_changes AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger, source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'stage_date_changes', audit.operation_id
    FROM public.stage_date_changes AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger, source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'business_target_date_changes', audit.operation_id
    FROM public.business_target_date_changes AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger, source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'hierarchy_movement_events', audit.operation_id
    FROM public.hierarchy_movement_events AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'calendar_reschedule_changes', audit.date_operation_id
    FROM public.calendar_reschedule_changes AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.batch_operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'schedule_deletion_events', audit.operation_id
    FROM public.schedule_deletion_events AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'calendar_reschedule_reversals', audit.reversal_batch_operation_id
    FROM public.calendar_reschedule_reversals AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.reversal_batch_operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, link_kind
  ) SELECT p_workspace_id, p_product_id, v_schedule_version, v_operation_id,
      'calendar_reschedule_reversals', audit.original_batch_operation_id, 'reversal_of'
    FROM public.calendar_reschedule_reversals AS audit
    WHERE p_operation_id IS NOT NULL AND audit.workspace_id = p_workspace_id
      AND audit.product_id = p_product_id AND audit.reversal_batch_operation_id = v_operation_id
    ON CONFLICT DO NOTHING;
  RETURN v_event_id;
END;
$$;

CREATE FUNCTION public.capture_product_schedule_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_old_semantic jsonb;
  v_new_semantic jsonb;
  v_previous jsonb := '{}'::jsonb;
  v_after jsonb := '{}'::jsonb;
  v_workspace_id uuid;
  v_product_id uuid;
  v_entity_id uuid;
  v_actor_id uuid;
  v_operation_id uuid;
  v_reversal_of uuid;
  v_operation_type text;
  v_justification text;
  v_change_type text;
  v_parent_before jsonb := '{}'::jsonb;
  v_parent_after jsonb := '{}'::jsonb;
  v_reason_required boolean := false;
  v_structural boolean := false;
  v_deleted boolean := false;
  v_date_change boolean := false;
  v_key text;
  v_reference record;
BEGIN
  IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW); END IF;

  IF TG_TABLE_NAME = 'stage_definitions' THEN
    IF TG_OP <> 'UPDATE' OR v_old->'code' IS NOT DISTINCT FROM v_new->'code' AND
       v_old->'color' IS NOT DISTINCT FROM v_new->'color' THEN
      RETURN NEW;
    END IF;
    v_workspace_id := (v_new->>'workspace_id')::uuid;
    v_entity_id := (v_new->>'id')::uuid;
  ELSIF TG_TABLE_NAME = 'products' THEN
    v_workspace_id := COALESCE((v_new->>'workspace_id')::uuid, (v_old->>'workspace_id')::uuid);
    v_product_id := COALESCE((v_new->>'id')::uuid, (v_old->>'id')::uuid);
    v_entity_id := v_product_id;
  ELSE
    v_workspace_id := COALESCE((v_new->>'workspace_id')::uuid, (v_old->>'workspace_id')::uuid);
    v_product_id := COALESCE((v_new->>'product_id')::uuid, (v_old->>'product_id')::uuid);
    v_entity_id := COALESCE((v_new->>'id')::uuid, (v_old->>'id')::uuid);
  END IF;

  v_actor_id := COALESCE(
    NULLIF(current_setting('jlproject.schedule_actor_id', true), '')::uuid,
    NULLIF(COALESCE(v_new->>'updated_by', v_new->>'created_by',
      v_old->>'updated_by', v_old->>'created_by'), '')::uuid,
    NULLIF(current_setting('jlproject.stage_date_actor_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.date_actor_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.target_actor_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.hierarchy_actor_id', true), '')::uuid
  );
  v_operation_id := COALESCE(
    NULLIF(current_setting('jlproject.schedule_operation_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.stage_date_operation_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.date_operation_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.target_operation_id', true), '')::uuid,
    NULLIF(current_setting('jlproject.hierarchy_operation_id', true), '')::uuid,
    NULLIF(v_new->>'deletion_operation_id', '')::uuid
  );
  v_justification := COALESCE(
    NULLIF(current_setting('jlproject.schedule_justification', true), ''),
    NULLIF(current_setting('jlproject.stage_date_reason', true), ''),
    NULLIF(current_setting('jlproject.date_change_reason', true), ''),
    NULLIF(current_setting('jlproject.target_change_reason', true), '')
  );
  v_reversal_of := NULLIF(current_setting('jlproject.schedule_reversal_of', true), '')::uuid;
  v_operation_type := NULLIF(current_setting('jlproject.schedule_operation_type', true), '');

  IF TG_TABLE_NAME = 'stage_definitions' THEN
    v_operation_type := COALESCE(v_operation_type, 'stage_definition_color_changed');
    v_change_type := 'stage_definition_updated';
    v_old_semantic := v_old - ARRAY['id', 'workspace_id'];
    v_new_semantic := v_new - ARRAY['id', 'workspace_id'];
    SELECT COALESCE(jsonb_object_agg(key, value), '{}'::jsonb) INTO v_previous
      FROM jsonb_each(v_old_semantic) AS old_value(key, value)
      WHERE v_new_semantic->key IS DISTINCT FROM value;
    SELECT COALESCE(jsonb_object_agg(key, value), '{}'::jsonb) INTO v_after
      FROM jsonb_each(v_new_semantic) AS new_value(key, value)
      WHERE v_old_semantic->key IS DISTINCT FROM value;
    IF v_previous = '{}'::jsonb AND v_after = '{}'::jsonb THEN RETURN NEW; END IF;
    FOR v_reference IN
      SELECT DISTINCT product.workspace_id, product.id AS product_id,
        stage.id AS stage_id, stage.discipline_id
      FROM public.discipline_stages AS stage
      JOIN public.products AS product ON product.workspace_id = stage.workspace_id
        AND product.id = stage.product_id
      WHERE stage.workspace_id = v_workspace_id AND stage.definition_id = v_entity_id
        AND stage.deleted_at IS NULL
    LOOP
      PERFORM public.write_product_schedule_operation_event(
        v_reference.workspace_id, v_reference.product_id, v_actor_id, v_operation_id,
        v_operation_type, v_justification, v_reversal_of, 'stage_definition', v_entity_id,
        v_change_type, jsonb_build_object('stageId', v_reference.stage_id,
          'disciplineId', v_reference.discipline_id),
        jsonb_build_object('stageId', v_reference.stage_id,
          'disciplineId', v_reference.discipline_id), v_previous, v_after
      );
    END LOOP;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'products' AND TG_OP = 'INSERT' THEN
    INSERT INTO public.product_schedule_state (workspace_id, product_id)
      VALUES (v_workspace_id, v_product_id) ON CONFLICT (workspace_id, product_id) DO NOTHING;
  END IF;

  v_old_semantic := CASE WHEN v_old IS NULL THEN NULL ELSE
    v_old - ARRAY['id', 'workspace_id', 'product_id', 'created_at', 'created_by',
      'updated_at', 'updated_by', 'version'] END;
  v_new_semantic := CASE WHEN v_new IS NULL THEN NULL ELSE
    v_new - ARRAY['id', 'workspace_id', 'product_id', 'created_at', 'created_by',
      'updated_at', 'updated_by', 'version'] END;
  IF TG_OP = 'UPDATE' AND v_old_semantic IS NOT DISTINCT FROM v_new_semantic THEN RETURN NEW; END IF;

  v_structural := TG_OP = 'UPDATE' AND
    (v_old->'display_order' IS DISTINCT FROM v_new->'display_order' OR
     v_old->'discipline_id' IS DISTINCT FROM v_new->'discipline_id' OR
     v_old->'stage_id' IS DISTINCT FROM v_new->'stage_id');
  v_deleted := TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND
    v_old->>'deleted_at' IS NULL AND v_new->>'deleted_at' IS NOT NULL);
  v_date_change := TG_OP = 'UPDATE' AND (
    v_old->'planned_start' IS DISTINCT FROM v_new->'planned_start' OR
    v_old->'planned_end' IS DISTINCT FROM v_new->'planned_end' OR
    v_old->'target_date' IS DISTINCT FROM v_new->'target_date');
  IF TG_OP = 'INSERT' THEN
    v_date_change := (TG_TABLE_NAME = 'stage_activities' AND
        (v_new->>'planned_start' IS NOT NULL OR v_new->>'planned_end' IS NOT NULL)) OR
      (TG_TABLE_NAME = 'discipline_stages' AND
        (v_new->>'planned_start' IS NOT NULL OR v_new->>'planned_end' IS NOT NULL)) OR
      (TG_TABLE_NAME = 'business_targets' AND v_new->>'target_date' IS NOT NULL);
    IF v_date_change AND COALESCE(v_operation_type, (
        SELECT operation.operation_type
        FROM public.product_schedule_operations AS operation
        WHERE operation.workspace_id = v_workspace_id AND operation.product_id = v_product_id
          AND operation.transaction_id = pg_current_xact_id()
        LIMIT 1
      ), '') IN ('product_created', 'schedule_imported') THEN
      v_date_change := false;
    END IF;
  END IF;
  v_reason_required := v_structural OR v_deleted OR v_date_change;
  IF v_reason_required AND (v_justification IS NULL OR
      char_length(v_justification) NOT BETWEEN 10 AND 2000 OR
      v_justification <> btrim(v_justification) OR v_justification ~ '[[:cntrl:]]') THEN
    RAISE EXCEPTION 'A valid justification is required for this schedule operation.' USING ERRCODE = '23514';
  END IF;

  IF TG_TABLE_NAME = 'products' THEN
    v_operation_type := COALESCE(v_operation_type,
      CASE WHEN TG_OP = 'INSERT' THEN 'product_created'
        WHEN v_old->'active' IS DISTINCT FROM v_new->'active' AND v_new->>'active' = 'false'
          THEN 'product_archived' ELSE 'product_metadata_updated' END);
    v_parent_before := '{}'::jsonb;
    v_parent_after := '{}'::jsonb;
  ELSE
    v_operation_type := COALESCE(v_operation_type,
      CASE WHEN v_deleted THEN 'schedule_deleted'
        WHEN v_structural THEN 'hierarchy_moved'
        WHEN v_date_change THEN 'schedule_dates_changed'
        WHEN TG_OP = 'INSERT' THEN 'schedule_entity_created'
        ELSE 'schedule_metadata_updated' END);
  END IF;
  v_change_type := CASE WHEN TG_OP = 'INSERT' THEN TG_TABLE_NAME || '_created'
    WHEN TG_OP = 'DELETE' THEN TG_TABLE_NAME || '_physically_deleted'
    WHEN v_deleted THEN TG_TABLE_NAME || '_deleted'
    WHEN v_structural THEN TG_TABLE_NAME || '_moved'
    WHEN v_date_change THEN TG_TABLE_NAME || '_dates_changed'
    ELSE TG_TABLE_NAME || '_updated' END;

  IF TG_TABLE_NAME = 'product_disciplines' THEN
    v_parent_before := jsonb_build_object('productId', v_product_id);
    v_parent_after := jsonb_build_object('productId', v_product_id);
  ELSIF TG_TABLE_NAME = 'discipline_stages' THEN
    v_parent_before := jsonb_build_object('disciplineId', v_old->'discipline_id');
    v_parent_after := jsonb_build_object('disciplineId', v_new->'discipline_id');
  ELSIF TG_TABLE_NAME = 'stage_activities' THEN
    v_parent_before := jsonb_build_object('disciplineId', v_old->'discipline_id', 'stageId', v_old->'stage_id');
    v_parent_after := jsonb_build_object('disciplineId', v_new->'discipline_id', 'stageId', v_new->'stage_id');
  ELSIF TG_TABLE_NAME = 'business_targets' THEN
    v_parent_before := jsonb_build_object('productId', v_product_id);
    v_parent_after := jsonb_build_object('productId', v_product_id);
  END IF;

  IF v_old_semantic IS NOT NULL THEN
    FOR v_key IN SELECT jsonb_object_keys(v_old_semantic) LOOP
      IF v_new_semantic IS NULL OR v_old_semantic->v_key IS DISTINCT FROM v_new_semantic->v_key THEN
        v_previous := v_previous || jsonb_build_object(v_key, v_old_semantic->v_key);
      END IF;
    END LOOP;
  END IF;
  IF v_new_semantic IS NOT NULL THEN
    FOR v_key IN SELECT jsonb_object_keys(v_new_semantic) LOOP
      IF v_old_semantic IS NULL OR v_old_semantic->v_key IS DISTINCT FROM v_new_semantic->v_key THEN
        v_after := v_after || jsonb_build_object(v_key, v_new_semantic->v_key);
      END IF;
    END LOOP;
  END IF;

  -- Specialized append-only ledgers retain the sensitive schedule fields. The
  -- operation link below points to those records instead of repeating them.
  IF TG_TABLE_NAME = 'stage_activities' AND v_date_change AND TG_OP = 'UPDATE' AND
      v_operation_type IN ('activity_dates_changed', 'activity_working_plan_changed',
        'calendar_rescheduled', 'calendar_reschedule_reversed') THEN
    v_previous := v_previous - ARRAY['planned_start', 'planned_end'];
    v_after := v_after - ARRAY['planned_start', 'planned_end'];
  ELSIF TG_TABLE_NAME = 'discipline_stages' AND v_date_change AND TG_OP = 'UPDATE' AND
      v_operation_type = 'stage_dates_changed' THEN
    v_previous := v_previous - ARRAY['planned_start', 'planned_end'];
    v_after := v_after - ARRAY['planned_start', 'planned_end'];
  ELSIF TG_TABLE_NAME = 'business_targets' AND v_date_change AND TG_OP = 'UPDATE' AND
      v_operation_type IN ('business_target_updated', 'business_target_date_changed') THEN
    v_previous := v_previous - ARRAY['target_date'];
    v_after := v_after - ARRAY['target_date'];
  END IF;
  IF v_structural THEN
    v_previous := v_previous - ARRAY['display_order', 'discipline_id', 'stage_id'];
    v_after := v_after - ARRAY['display_order', 'discipline_id', 'stage_id'];
  END IF;
  PERFORM public.write_product_schedule_operation_event(
    v_workspace_id, v_product_id, v_actor_id, v_operation_id, v_operation_type,
    v_justification, v_reversal_of, TG_TABLE_NAME, v_entity_id, v_change_type,
    v_parent_before, v_parent_after, v_previous, v_after
  );
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.link_product_schedule_audit_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_row jsonb;
  v_workspace_id uuid;
  v_product_id uuid;
  v_source_operation_id uuid;
  v_original_operation_id uuid;
  v_operation public.product_schedule_operations%ROWTYPE;
BEGIN
  v_row := to_jsonb(NEW);
  v_workspace_id := (v_row->>'workspace_id')::uuid;
  v_product_id := (v_row->>'product_id')::uuid;
  v_source_operation_id := COALESCE(NULLIF(v_row->>'operation_id', '')::uuid,
    NULLIF(v_row->>'date_operation_id', '')::uuid,
    NULLIF(v_row->>'reversal_batch_operation_id', '')::uuid,
    NULLIF(v_row->>'reversal_date_operation_id', '')::uuid);
  v_original_operation_id := COALESCE(NULLIF(v_row->>'original_operation_id', '')::uuid,
    NULLIF(v_row->>'reversed_operation_id', '')::uuid,
    NULLIF(v_row->>'original_batch_operation_id', '')::uuid,
    NULLIF(v_row->>'original_date_operation_id', '')::uuid);
  IF TG_TABLE_NAME = 'schedule_deletion_events' THEN
    PERFORM public.write_product_schedule_operation_event(
      v_workspace_id, v_product_id, (v_row->>'actor_id')::uuid,
      (v_row->>'operation_id')::uuid, 'schedule_deleted', v_row->>'reason', NULL,
      v_row->>'target_kind', (v_row->>'target_id')::uuid, 'schedule_deleted',
      COALESCE(v_row->'affected_items', '{}'::jsonb), '{}'::jsonb,
      COALESCE(v_row->'affected_items', '{}'::jsonb), '{}'::jsonb
    );
  END IF;
  IF v_source_operation_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO v_operation FROM public.product_schedule_operations AS operation
    WHERE operation.workspace_id = v_workspace_id AND operation.product_id = v_product_id
      AND operation.transaction_id = pg_current_xact_id();
  IF NOT FOUND THEN RETURN NEW; END IF;
  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, link_kind
  ) VALUES (
    v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
    TG_TABLE_NAME, v_source_operation_id, 'audit_detail'
  ) ON CONFLICT DO NOTHING;
  IF v_original_operation_id IS NOT NULL THEN
    INSERT INTO public.product_schedule_operation_links (
      workspace_id, product_id, schedule_version, operation_id, source_ledger,
      source_operation_id, link_kind
    ) VALUES (
      v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
      'reversal_of:' || TG_TABLE_NAME, v_original_operation_id, 'reversal_of'
    ) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.read_product_schedule_cursor(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid
) RETURNS TABLE (schedule_version bigint, history_watermark bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  SELECT state.schedule_version, state.history_watermark
  FROM public.product_schedule_state AS state
  JOIN public.products AS product ON product.workspace_id = state.workspace_id
    AND product.id = state.product_id
  JOIN public.workspace_memberships AS membership ON membership.workspace_id = state.workspace_id
    AND membership.auth_user_id = p_actor_id AND membership.active
    AND membership.role IN ('admin', 'editor', 'viewer')
  WHERE state.workspace_id = p_workspace_id AND state.product_id = p_product_id
$$;

CREATE FUNCTION public.list_product_schedule_operations(
  p_workspace_id uuid,
  p_product_id uuid,
  p_actor_id uuid,
  p_before_version bigint,
  p_limit integer
) RETURNS TABLE (
  schedule_version bigint,
  operation_id uuid,
  actor_id uuid,
  occurred_at timestamptz,
  operation_type text,
  justification text,
  reversal_of_operation_id uuid,
  events jsonb,
  source_operations jsonb
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  SELECT operation.schedule_version, operation.operation_id, operation.actor_id,
    operation.occurred_at, operation.operation_type, operation.justification,
    operation.reversal_of_operation_id,
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'eventId', event.event_id, 'entityType', event.entity_type, 'entityId', event.entity_id,
      'changeType', event.change_type, 'parentBefore', event.parent_before,
      'parentAfter', event.parent_after, 'previousValues', event.previous_values,
      'newValues', event.new_values
    ) ORDER BY event.event_id) FROM public.product_schedule_operation_events AS event
      WHERE event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
        AND event.schedule_version = operation.schedule_version), '[]'::jsonb) AS events,
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'ledger', link.source_ledger, 'operationId', link.source_operation_id, 'kind', link.link_kind
    ) ORDER BY link.source_ledger, link.source_operation_id)
      FROM public.product_schedule_operation_links AS link
      WHERE link.workspace_id = operation.workspace_id AND link.product_id = operation.product_id
        AND link.schedule_version = operation.schedule_version), '[]'::jsonb) AS source_operations
  FROM public.product_schedule_operations AS operation
  WHERE operation.workspace_id = p_workspace_id AND operation.product_id = p_product_id
    AND (p_before_version IS NULL OR operation.schedule_version < p_before_version)
    AND p_limit BETWEEN 1 AND 100
    AND EXISTS (SELECT 1 FROM public.workspace_memberships AS membership
      WHERE membership.workspace_id = p_workspace_id AND membership.auth_user_id = p_actor_id
        AND membership.active AND membership.role IN ('admin', 'editor', 'viewer'))
  ORDER BY operation.schedule_version DESC
  LIMIT p_limit
$$;

CREATE FUNCTION public.delete_business_target_with_reason(
  p_workspace_id uuid, p_product_id uuid, p_target_id uuid, p_actor_id uuid,
  p_operation_id uuid, p_expected_version bigint, p_reason text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_reason text := btrim(p_reason);
BEGIN
  IF p_operation_id IS NULL OR p_actor_id IS NULL OR p_expected_version IS NULL OR
     p_expected_version < 1 OR v_reason IS NULL OR char_length(v_reason) NOT BETWEEN 10 AND 2000 OR
     v_reason ~ '[[:cntrl:]]' THEN RETURN 'invalid'; END IF;
  PERFORM set_config('jlproject.schedule_actor_id', p_actor_id::text, true);
  PERFORM set_config('jlproject.schedule_operation_id', p_operation_id::text, true);
  PERFORM set_config('jlproject.schedule_operation_type', 'business_target_deleted', true);
  PERFORM set_config('jlproject.schedule_justification', v_reason, true);
  RETURN public.delete_business_target(p_workspace_id, p_product_id, p_target_id,
    p_actor_id, p_operation_id, p_expected_version);
END;
$$;

CREATE TRIGGER products_schedule_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.capture_product_schedule_mutation();
CREATE TRIGGER product_disciplines_schedule_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.product_disciplines
  FOR EACH ROW EXECUTE FUNCTION public.capture_product_schedule_mutation();
CREATE TRIGGER discipline_stages_schedule_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.discipline_stages
  FOR EACH ROW EXECUTE FUNCTION public.capture_product_schedule_mutation();
CREATE TRIGGER stage_activities_schedule_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.stage_activities
  FOR EACH ROW EXECUTE FUNCTION public.capture_product_schedule_mutation();
CREATE TRIGGER business_targets_schedule_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.business_targets
  FOR EACH ROW EXECUTE FUNCTION public.capture_product_schedule_mutation();
CREATE TRIGGER stage_definitions_schedule_audit
  AFTER UPDATE ON public.stage_definitions
  FOR EACH ROW EXECUTE FUNCTION public.capture_product_schedule_mutation();

GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;
CREATE TRIGGER activity_date_changes_schedule_link
  AFTER INSERT ON public.activity_date_changes FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
CREATE TRIGGER stage_date_changes_schedule_link
  AFTER INSERT ON public.stage_date_changes FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
CREATE TRIGGER business_target_date_changes_schedule_link
  AFTER INSERT ON public.business_target_date_changes FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
CREATE TRIGGER calendar_reschedule_changes_schedule_link
  AFTER INSERT ON public.calendar_reschedule_changes FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
CREATE TRIGGER calendar_reschedule_reversals_schedule_link
  AFTER INSERT ON public.calendar_reschedule_reversals FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
CREATE TRIGGER hierarchy_movement_events_schedule_link
  AFTER INSERT ON public.hierarchy_movement_events FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
CREATE TRIGGER schedule_deletion_events_schedule_link
  AFTER INSERT ON public.schedule_deletion_events FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_audit_source();
RESET ROLE;

REVOKE ALL ON public.product_schedule_state, public.product_schedule_operations,
  public.product_schedule_operation_events, public.product_schedule_operation_links FROM PUBLIC, jlproject_worker;
REVOKE ALL ON FUNCTION public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb),
  public.capture_product_schedule_mutation(), public.link_product_schedule_audit_source(),
  public.read_product_schedule_cursor(uuid,uuid,uuid),
  public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer),
  public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb),
  public.capture_product_schedule_mutation(), public.link_product_schedule_audit_source()
  FROM jlproject_worker;

GRANT SELECT ON public.products, public.product_disciplines, public.discipline_stages,
  public.stage_activities, public.business_targets, public.stage_definitions,
  public.workspace_memberships TO jlproject_date_executor;
GRANT INSERT, UPDATE ON public.product_schedule_state TO jlproject_date_executor;
GRANT INSERT ON public.product_schedule_operations, public.product_schedule_operation_events,
  public.product_schedule_operation_links TO jlproject_date_executor;
GRANT EXECUTE ON FUNCTION public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)
  TO jlproject_date_executor;

GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
ALTER TABLE public.product_schedule_state OWNER TO jlproject_date_executor;
ALTER TABLE public.product_schedule_operations OWNER TO jlproject_date_executor;
ALTER TABLE public.product_schedule_operation_events OWNER TO jlproject_date_executor;
ALTER TABLE public.product_schedule_operation_links OWNER TO jlproject_date_executor;
ALTER FUNCTION public.prevent_product_schedule_audit_mutation() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.write_product_schedule_operation_event(uuid,uuid,uuid,uuid,text,text,uuid,text,uuid,text,jsonb,jsonb,jsonb,jsonb)
  OWNER TO jlproject_date_executor;
ALTER FUNCTION public.capture_product_schedule_mutation() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.link_product_schedule_audit_source() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.read_product_schedule_cursor(uuid,uuid,uuid) OWNER TO jlproject_date_executor;
ALTER FUNCTION public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)
  OWNER TO jlproject_date_executor;
ALTER FUNCTION public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)
  OWNER TO jlproject_date_executor;
SET ROLE jlproject_date_executor;
REVOKE ALL ON FUNCTION public.delete_business_target(uuid,uuid,uuid,uuid,uuid,bigint)
  FROM PUBLIC, jlproject_worker;
GRANT EXECUTE ON FUNCTION public.read_product_schedule_cursor(uuid,uuid,uuid),
  public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer),
  public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text) TO jlproject_worker;
RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
BEGIN
  IF has_table_privilege('jlproject_worker', 'public.product_schedule_state', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_state', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_links', 'SELECT') OR
     NOT has_function_privilege('jlproject_worker',
       'public.read_product_schedule_cursor(uuid,uuid,uuid)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)', 'EXECUTE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.delete_business_target_with_reason(uuid,uuid,uuid,uuid,uuid,bigint,text)', 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.delete_business_target(uuid,uuid,uuid,uuid,uuid,bigint)', 'EXECUTE') OR
     has_function_privilege('public', 'public.read_product_schedule_cursor(uuid,uuid,uuid)', 'EXECUTE') OR
     has_function_privilege('public', 'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)', 'EXECUTE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     (SELECT count(*) <> 6 FROM pg_trigger WHERE NOT tgisinternal AND
       tgname IN ('products_schedule_audit', 'product_disciplines_schedule_audit',
         'discipline_stages_schedule_audit', 'stage_activities_schedule_audit',
         'business_targets_schedule_audit', 'stage_definitions_schedule_audit')) THEN
    RAISE EXCEPTION 'Phase 1 audit ownership, trigger coverage, or Worker privileges are incorrect.';
  END IF;
END;
$$;

COMMIT;
