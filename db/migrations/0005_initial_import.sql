BEGIN;

CREATE TABLE public.business_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 200),
  target_date date NOT NULL,
  operational_date date,
  source_external_id text NOT NULL CHECK (source_external_id ~ '^T[0-9]{3}$'),
  source_row integer NOT NULL CHECK (source_row BETWEEN 4 AND 8),
  display_order integer NOT NULL CHECK (display_order >= 0),
  source_status text CHECK (source_status IS NULL OR char_length(source_status) <= 200),
  notes text CHECK (notes IS NULL OR char_length(notes) <= 4000),
  created_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_targets_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT business_targets_scope_id_unique UNIQUE (workspace_id, product_id, id),
  CONSTRAINT business_targets_source_unique UNIQUE (product_id, source_external_id)
);
CREATE UNIQUE INDEX business_targets_name_unique_idx ON public.business_targets (product_id, lower(name));
CREATE INDEX business_targets_order_idx ON public.business_targets (workspace_id, product_id, display_order, id);

CREATE TABLE public.import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL UNIQUE,
  idempotency_key uuid NOT NULL,
  source_hash text NOT NULL CHECK (source_hash ~ '^[0-9a-f]{64}$'),
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  source_filename text NOT NULL CHECK (char_length(source_filename) BETWEEN 1 AND 255),
  created_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT import_batches_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT import_batches_workspace_key_unique UNIQUE (workspace_id, idempotency_key),
  CONSTRAINT import_batches_workspace_source_unique UNIQUE (workspace_id, source_hash),
  CONSTRAINT import_batches_scope_id_unique UNIQUE (workspace_id, product_id, id)
);

CREATE TABLE public.import_source_rows (
  import_batch_id uuid NOT NULL REFERENCES public.import_batches(id) ON DELETE RESTRICT,
  source_sheet text NOT NULL CHECK (source_sheet IN ('Cronograma Produto', 'Metas e Premissas')),
  source_row integer NOT NULL CHECK (source_row BETWEEN 4 AND 50),
  source_external_id text CHECK (source_external_id IS NULL OR source_external_id ~ '^T[0-9]{3}$'),
  activity_id uuid REFERENCES public.stage_activities(id) ON DELETE RESTRICT,
  target_id uuid REFERENCES public.business_targets(id) ON DELETE RESTRICT,
  PRIMARY KEY (import_batch_id, source_sheet, source_row),
  CONSTRAINT import_source_rows_entity_check CHECK (
    (activity_id IS NOT NULL AND target_id IS NULL AND source_external_id IS NOT NULL) OR
    (activity_id IS NULL AND target_id IS NOT NULL)
  )
);
CREATE UNIQUE INDEX import_source_rows_external_id_unique_idx
  ON public.import_source_rows (import_batch_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE INDEX import_source_rows_target_idx ON public.import_source_rows (target_id);

CREATE TABLE public.initial_schedule_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL UNIQUE,
  import_batch_id uuid NOT NULL UNIQUE,
  label text NOT NULL DEFAULT 'R00' CHECK (label = 'R00'),
  kind text NOT NULL DEFAULT 'baseline' CHECK (kind = 'baseline'),
  snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object' AND
    snapshot ? 'dependencies' AND snapshot->'dependencies' = '[]'::jsonb),
  created_by uuid NOT NULL REFERENCES neon_auth."user"(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT initial_revisions_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT initial_revisions_batch_fk FOREIGN KEY (workspace_id, product_id, import_batch_id)
    REFERENCES public.import_batches(workspace_id, product_id, id) ON DELETE RESTRICT
);

CREATE FUNCTION public.prevent_initial_revision_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
BEGIN
  RAISE EXCEPTION 'Initial schedule revisions are immutable.' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER initial_schedule_revisions_immutable
  BEFORE UPDATE OR DELETE ON public.initial_schedule_revisions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_initial_revision_mutation();
REVOKE ALL ON FUNCTION public.prevent_initial_revision_mutation() FROM PUBLIC;

CREATE FUNCTION public.import_initial_schedule(
  p_workspace_id uuid, p_actor_id uuid, p_idempotency_key uuid,
  p_source_hash text, p_request_hash text, p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog
AS $$
DECLARE
  v_existing record;
  v_product_id uuid;
  v_batch_id uuid;
  v_revision_id uuid;
  v_discipline_id uuid;
  v_stage_id uuid;
  v_definition_id uuid;
  v_activity_id uuid;
  v_target_id uuid;
  v_discipline jsonb;
  v_stage jsonb;
  v_activity jsonb;
  v_target jsonb;
  v_meta jsonb;
BEGIN
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'denied'); END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor');
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'denied'); END IF;

  SELECT batch.request_hash, batch.product_id, revision.id AS revision_id INTO v_existing
    FROM public.import_batches AS batch
    JOIN public.initial_schedule_revisions AS revision ON revision.import_batch_id = batch.id
    WHERE batch.workspace_id = p_workspace_id AND batch.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_hash <> p_request_hash THEN RETURN jsonb_build_object('status', 'conflict'); END IF;
    RETURN jsonb_build_object('status', 'replayed', 'productId', v_existing.product_id,
      'revisionId', v_existing.revision_id, 'revisionLabel', 'R00');
  END IF;
  IF EXISTS (SELECT 1 FROM public.import_batches
      WHERE workspace_id = p_workspace_id AND source_hash = p_source_hash) THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (p_workspace_id, p_payload->>'productName', p_actor_id, p_actor_id)
    RETURNING id INTO v_product_id;
  INSERT INTO public.import_batches (workspace_id, product_id, idempotency_key,
    source_hash, request_hash, source_filename, created_by)
    VALUES (p_workspace_id, v_product_id, p_idempotency_key, p_source_hash,
      p_request_hash, p_payload->>'sourceFilename', p_actor_id)
    RETURNING id INTO v_batch_id;

  FOR v_discipline IN SELECT value FROM jsonb_array_elements(p_payload->'disciplines') LOOP
    INSERT INTO public.product_disciplines (workspace_id, product_id, name, short_code,
      color, display_order, created_by, updated_by)
      VALUES (p_workspace_id, v_product_id, v_discipline->>'name', v_discipline->>'shortCode',
        v_discipline->>'color', (v_discipline->>'displayOrder')::integer, p_actor_id, p_actor_id)
      RETURNING id INTO v_discipline_id;
    FOR v_stage IN SELECT value FROM jsonb_array_elements(v_discipline->'stages') LOOP
      SELECT id INTO v_definition_id FROM public.stage_definitions
        WHERE workspace_id = p_workspace_id AND lower(code) = lower(v_stage->>'code');
      IF NOT FOUND THEN
        INSERT INTO public.stage_definitions (workspace_id, code, color)
          VALUES (p_workspace_id, v_stage->>'code', v_stage->>'color')
          RETURNING id INTO v_definition_id;
      END IF;
      INSERT INTO public.discipline_stages (workspace_id, product_id, discipline_id,
        definition_id, display_name, display_order, created_by, updated_by)
        VALUES (p_workspace_id, v_product_id, v_discipline_id, v_definition_id,
          v_stage->>'displayName', (v_stage->>'displayOrder')::integer, p_actor_id, p_actor_id)
        RETURNING id INTO v_stage_id;
      FOR v_activity IN SELECT value FROM jsonb_array_elements(v_stage->'activities') LOOP
        INSERT INTO public.stage_activities (workspace_id, product_id, discipline_id, stage_id,
          name, activity_type, planned_start, planned_end, display_order, notes,
          source_external_id, created_by, updated_by)
          VALUES (p_workspace_id, v_product_id, v_discipline_id, v_stage_id,
            v_activity->>'name', v_activity->>'activityType',
            (v_activity->>'plannedStart')::date, (v_activity->>'plannedEnd')::date,
            (v_activity->>'displayOrder')::integer, v_activity->>'notes',
            v_activity->>'sourceId', p_actor_id, p_actor_id)
          RETURNING id INTO v_activity_id;
        INSERT INTO public.import_source_rows (import_batch_id, source_sheet, source_row,
          source_external_id, activity_id)
          VALUES (v_batch_id, 'Cronograma Produto', (v_activity->>'sourceRow')::integer,
            v_activity->>'sourceId', v_activity_id);
      END LOOP;
    END LOOP;
  END LOOP;

  FOR v_target IN SELECT value FROM jsonb_array_elements(p_payload->'targets') LOOP
    INSERT INTO public.business_targets (workspace_id, product_id, name, target_date,
      operational_date, source_external_id, source_row, display_order, source_status,
      notes, created_by)
      VALUES (p_workspace_id, v_product_id, v_target->>'name',
        (v_target->>'targetDate')::date, (v_target->>'operationalDate')::date,
        v_target->>'matchedSourceId', (v_target->>'sourceRow')::integer,
        (v_target->>'displayOrder')::integer, v_target->>'status', v_target->>'notes', p_actor_id)
      RETURNING id INTO v_target_id;
    SELECT value INTO v_meta FROM jsonb_array_elements(p_payload->'sourceMeta')
      WHERE value->>'sourceId' = v_target->>'matchedSourceId';
    INSERT INTO public.import_source_rows (import_batch_id, source_sheet, source_row,
      source_external_id, target_id)
      VALUES (v_batch_id, 'Cronograma Produto', (v_meta->>'sourceRow')::integer,
        v_target->>'matchedSourceId', v_target_id);
    INSERT INTO public.import_source_rows (import_batch_id, source_sheet, source_row, target_id)
      VALUES (v_batch_id, 'Metas e Premissas', (v_target->>'sourceRow')::integer, v_target_id);
  END LOOP;

  INSERT INTO public.initial_schedule_revisions (workspace_id, product_id, import_batch_id,
    snapshot, created_by)
    VALUES (p_workspace_id, v_product_id, v_batch_id,
      jsonb_build_object(
        'product', jsonb_build_object('id', v_product_id, 'name', p_payload->>'productName'),
        'disciplines', p_payload->'disciplines',
        'sourceMeta', p_payload->'sourceMeta', 'targets', p_payload->'targets',
        'actualStageColors', (SELECT COALESCE(jsonb_object_agg(lower(definition.code), definition.color), '{}'::jsonb)
          FROM public.discipline_stages AS stage
          JOIN public.stage_definitions AS definition ON definition.id = stage.definition_id
          WHERE stage.product_id = v_product_id),
        'disciplineIds', (SELECT COALESCE(jsonb_object_agg(discipline.name, discipline.id::text), '{}'::jsonb)
          FROM public.product_disciplines AS discipline WHERE discipline.product_id = v_product_id),
        'stageIds', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', stage.id,
          'disciplineId', stage.discipline_id, 'code', definition.code,
          'displayName', stage.display_name) ORDER BY discipline.display_order, stage.display_order), '[]'::jsonb)
          FROM public.discipline_stages AS stage
          JOIN public.product_disciplines AS discipline ON discipline.id = stage.discipline_id
          JOIN public.stage_definitions AS definition ON definition.id = stage.definition_id
          WHERE stage.product_id = v_product_id),
        'activityIds', (SELECT COALESCE(jsonb_object_agg(activity.source_external_id, activity.id::text), '{}'::jsonb)
          FROM public.stage_activities AS activity WHERE activity.product_id = v_product_id),
        'dependencies', '[]'::jsonb
      ), p_actor_id)
    RETURNING id INTO v_revision_id;
  RETURN jsonb_build_object('status', 'created', 'productId', v_product_id,
    'revisionId', v_revision_id, 'revisionLabel', 'R00');
END;
$$;
REVOKE ALL ON FUNCTION public.import_initial_schedule(uuid, uuid, uuid, text, text, jsonb) FROM PUBLIC;

COMMIT;
