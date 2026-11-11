BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.hierarchy_movement_events') IS NOT NULL OR
     to_regprocedure('public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)') IS NOT NULL OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname = 'stage_activities_parent_fk' AND contype = 'f' AND NOT condeferrable) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_activity_fk' AND contype = 'f') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_product_scope_fk' AND contype = 'f') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_dates_immutable' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
       AND tgname = 'stage_activities_deletion_guard' AND tgenabled IN ('O', 'A')) OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option)
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') THEN
    RAISE EXCEPTION 'Hierarchy movement migration prerequisites or role boundaries differ from the reviewed development state.';
  END IF;
END;
$$;

-- Date-audit parent columns describe the hierarchy at the time of the date
-- change. Product/activity scope remains enforced by the newer direct FK.
-- Preserve the existing administrative membership while granting only the
-- temporary ability to SET ROLE for this migration's ownership-sensitive DDL.
GRANT jlproject_date_executor TO neondb_owner
  WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;
ALTER TABLE public.activity_date_changes
  DROP CONSTRAINT activity_date_changes_activity_fk;
RESET ROLE;

-- A stage and its denormalized activity ancestry are changed in one operation.
-- Deferral permits both rows to be updated before ancestry is checked at commit.
ALTER TABLE public.stage_activities
  DROP CONSTRAINT stage_activities_parent_fk,
  ADD CONSTRAINT stage_activities_parent_fk
    FOREIGN KEY (workspace_id, product_id, discipline_id, stage_id)
    REFERENCES public.discipline_stages(workspace_id, product_id, discipline_id, id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY IMMEDIATE;

CREATE TABLE public.hierarchy_movement_events (
  operation_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  item_kind text NOT NULL CHECK (item_kind IN ('activity', 'stage', 'discipline')),
  item_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  original_discipline_id uuid,
  original_stage_id uuid,
  new_discipline_id uuid,
  new_stage_id uuid,
  original_display_order integer NOT NULL CHECK (original_display_order >= 0),
  new_display_order integer NOT NULL CHECK (new_display_order >= 0),
  version_before bigint NOT NULL CHECK (version_before > 0),
  version_after bigint NOT NULL CHECK (version_after = version_before + 1),
  source_order_before jsonb NOT NULL CHECK (jsonb_typeof(source_order_before) = 'array'),
  source_order_after jsonb NOT NULL CHECK (jsonb_typeof(source_order_after) = 'array'),
  destination_order_before jsonb NOT NULL CHECK (jsonb_typeof(destination_order_before) = 'array'),
  destination_order_after jsonb NOT NULL CHECK (jsonb_typeof(destination_order_after) = 'array'),
  descendant_activity_ids jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(descendant_activity_ids) = 'array'),
  CONSTRAINT hierarchy_movement_events_product_fk FOREIGN KEY (workspace_id, product_id)
    REFERENCES public.products(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT hierarchy_movement_events_actor_fk FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT,
  CONSTRAINT hierarchy_movement_events_parent_shape CHECK (
    (item_kind = 'discipline' AND original_discipline_id IS NULL AND original_stage_id IS NULL
      AND new_discipline_id IS NULL AND new_stage_id IS NULL) OR
    (item_kind = 'stage' AND original_discipline_id IS NOT NULL AND original_stage_id IS NULL
      AND new_discipline_id IS NOT NULL AND new_stage_id IS NULL) OR
    (item_kind = 'activity'
      AND ((original_discipline_id IS NULL AND original_stage_id IS NULL) OR
        (original_discipline_id IS NOT NULL AND original_stage_id IS NOT NULL))
      AND ((new_discipline_id IS NULL AND new_stage_id IS NULL) OR
        (new_discipline_id IS NOT NULL AND new_stage_id IS NOT NULL)))
  )
);
CREATE INDEX hierarchy_movement_events_scope_idx
  ON public.hierarchy_movement_events (workspace_id, product_id, changed_at DESC, operation_id DESC);
REVOKE ALL ON public.hierarchy_movement_events FROM PUBLIC, jlproject_worker;

GRANT USAGE, CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT SELECT ON public.workspaces, public.workspace_memberships, public.products,
  public.product_disciplines, public.discipline_stages, public.stage_activities
  TO jlproject_date_executor;
GRANT UPDATE (display_order, version, updated_by, updated_at)
  ON public.product_disciplines TO jlproject_date_executor;
GRANT UPDATE (discipline_id, display_order, version, updated_by, updated_at)
  ON public.discipline_stages TO jlproject_date_executor;
GRANT UPDATE (discipline_id, stage_id, display_order, version, updated_by, updated_at)
  ON public.stage_activities TO jlproject_date_executor;
ALTER TABLE public.hierarchy_movement_events OWNER TO jlproject_date_executor;

SET ROLE jlproject_date_executor;

CREATE FUNCTION public.guard_hierarchy_movement_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'Hierarchy movement audit is append-only.' USING ERRCODE = '23514';
END;
$$;
REVOKE ALL ON FUNCTION public.guard_hierarchy_movement_audit() FROM PUBLIC;
CREATE TRIGGER hierarchy_movement_events_immutable BEFORE UPDATE OR DELETE
  ON public.hierarchy_movement_events FOR EACH ROW
  EXECUTE FUNCTION public.guard_hierarchy_movement_audit();

CREATE FUNCTION public.remove_hierarchy_order(p_order jsonb, p_id uuid) RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(value ORDER BY ordinality), '[]'::jsonb)
  FROM jsonb_array_elements(p_order) WITH ORDINALITY AS item(value, ordinality)
  WHERE value <> to_jsonb(p_id::text)
$$;
REVOKE ALL ON FUNCTION public.remove_hierarchy_order(jsonb,uuid) FROM PUBLIC;

CREATE FUNCTION public.insert_hierarchy_order(p_order jsonb, p_id uuid, p_index integer) RETURNS jsonb
LANGUAGE sql IMMUTABLE STRICT SET search_path = pg_catalog, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(value ORDER BY sort_order, inserted DESC), '[]'::jsonb)
  FROM (
    SELECT value,
      CASE WHEN ordinality - 1 < p_index THEN ordinality - 1 ELSE ordinality END AS sort_order,
      false AS inserted
    FROM jsonb_array_elements(p_order) WITH ORDINALITY AS item(value, ordinality)
    UNION ALL
    SELECT to_jsonb(p_id::text), p_index, true
  ) AS ordered
$$;
REVOKE ALL ON FUNCTION public.insert_hierarchy_order(jsonb,uuid,integer) FROM PUBLIC;

CREATE FUNCTION public.move_schedule_item(
  p_workspace_id uuid, p_product_id uuid, p_actor_id uuid, p_operation_id uuid,
  p_kind text, p_target_id uuid, p_expected_version bigint,
  p_destination_discipline_id uuid, p_destination_stage_id uuid,
  p_destination_index integer, p_expected_source_order jsonb,
  p_expected_destination_order jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_version bigint;
  v_version_after bigint;
  v_original_order integer;
  v_original_discipline_id uuid;
  v_original_stage_id uuid;
  v_definition_id uuid;
  v_source_before jsonb;
  v_source_after jsonb;
  v_destination_before jsonb;
  v_destination_after jsonb;
  v_same_parent boolean;
  v_descendants jsonb := '[]'::jsonb;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_operation_id IS NULL OR p_target_id IS NULL OR p_kind NOT IN ('activity', 'stage', 'discipline') OR
     p_expected_version IS NULL OR p_expected_version < 1 OR
     p_destination_index IS NULL OR p_destination_index < 0 OR
     p_expected_source_order IS NULL OR p_expected_destination_order IS NULL OR
     jsonb_typeof(p_expected_source_order) <> 'array' OR
     jsonb_typeof(p_expected_destination_order) <> 'array' OR
     jsonb_array_length(p_expected_source_order) > 1000 OR
     jsonb_array_length(p_expected_destination_order) > 1000 OR
     EXISTS (SELECT 1 FROM jsonb_array_elements(p_expected_source_order) AS item(value)
       WHERE jsonb_typeof(value) <> 'string' OR value #>> '{}' !~
         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') OR
     EXISTS (SELECT 1 FROM jsonb_array_elements(p_expected_destination_order) AS item(value)
       WHERE jsonb_typeof(value) <> 'string' OR value #>> '{}' !~
         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') OR
     (SELECT count(*) <> count(DISTINCT value) FROM jsonb_array_elements(p_expected_source_order)) OR
     (SELECT count(*) <> count(DISTINCT value) FROM jsonb_array_elements(p_expected_destination_order)) OR
     (p_kind = 'discipline' AND (p_destination_discipline_id IS NOT NULL OR p_destination_stage_id IS NOT NULL)) OR
     (p_kind = 'stage' AND (p_destination_discipline_id IS NULL OR p_destination_stage_id IS NOT NULL)) OR
     (p_kind = 'activity' AND ((p_destination_discipline_id IS NULL) <> (p_destination_stage_id IS NULL))) THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  -- Existing writers lock one of these rows. Taking both in the established
  -- workspace-then-product order closes sibling-insert races during comparison.
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;
  PERFORM 1 FROM public.products
    WHERE workspace_id = p_workspace_id AND id = p_product_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;

  IF p_kind = 'discipline' THEN
    SELECT version, display_order INTO v_version, v_original_order
    FROM public.product_disciplines
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND id = p_target_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]'::jsonb)
      INTO v_source_before FROM public.product_disciplines
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND deleted_at IS NULL;
    v_destination_before := v_source_before;
    v_same_parent := true;
  ELSIF p_kind = 'stage' THEN
    SELECT version, display_order, discipline_id, definition_id
      INTO v_version, v_original_order, v_original_discipline_id, v_definition_id
    FROM public.discipline_stages
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND id = p_target_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    PERFORM 1 FROM public.product_disciplines
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND id = p_destination_discipline_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF EXISTS (SELECT 1 FROM public.discipline_stages
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND discipline_id = p_destination_discipline_id AND definition_id = v_definition_id
        AND id <> p_target_id) THEN
      RETURN jsonb_build_object('status', 'duplicate');
    END IF;
    SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]'::jsonb)
      INTO v_source_before FROM public.discipline_stages
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND discipline_id = v_original_discipline_id AND deleted_at IS NULL;
    SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]'::jsonb)
      INTO v_destination_before FROM public.discipline_stages
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id
        AND discipline_id = p_destination_discipline_id AND deleted_at IS NULL;
    v_same_parent := v_original_discipline_id = p_destination_discipline_id;
  ELSE
    SELECT version, display_order, discipline_id, stage_id
      INTO v_version, v_original_order, v_original_discipline_id, v_original_stage_id
    FROM public.stage_activities
    WHERE workspace_id = p_workspace_id AND product_id = p_product_id
      AND id = p_target_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF p_destination_stage_id IS NOT NULL THEN
      PERFORM 1 FROM public.discipline_stages AS stage
      JOIN public.product_disciplines AS discipline
        ON discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
        AND discipline.id = stage.discipline_id AND discipline.deleted_at IS NULL
      WHERE stage.workspace_id = p_workspace_id AND stage.product_id = p_product_id
        AND stage.discipline_id = p_destination_discipline_id AND stage.id = p_destination_stage_id
        AND stage.deleted_at IS NULL FOR UPDATE OF stage;
      IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    END IF;
    SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]'::jsonb)
      INTO v_source_before FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND deleted_at IS NULL
        AND discipline_id IS NOT DISTINCT FROM v_original_discipline_id
        AND stage_id IS NOT DISTINCT FROM v_original_stage_id;
    SELECT COALESCE(jsonb_agg(id::text ORDER BY display_order, id), '[]'::jsonb)
      INTO v_destination_before FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND deleted_at IS NULL
        AND discipline_id IS NOT DISTINCT FROM p_destination_discipline_id
        AND stage_id IS NOT DISTINCT FROM p_destination_stage_id;
    v_same_parent := v_original_discipline_id IS NOT DISTINCT FROM p_destination_discipline_id
      AND v_original_stage_id IS NOT DISTINCT FROM p_destination_stage_id;
  END IF;

  IF v_version <> p_expected_version THEN RETURN jsonb_build_object('status', 'stale'); END IF;
  IF v_source_before <> p_expected_source_order OR
     v_destination_before <> p_expected_destination_order THEN
    RETURN jsonb_build_object('status', 'conflict');
  END IF;

  v_source_after := public.remove_hierarchy_order(v_source_before, p_target_id);
  IF v_same_parent THEN
    IF p_destination_index > jsonb_array_length(v_source_after) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    v_destination_after := public.insert_hierarchy_order(v_source_after, p_target_id, p_destination_index);
    v_source_after := v_destination_after;
  ELSE
    IF p_destination_index > jsonb_array_length(v_destination_before) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    v_destination_after := public.insert_hierarchy_order(
      v_destination_before, p_target_id, p_destination_index);
  END IF;

  IF v_same_parent AND v_source_before = v_source_after THEN
    RETURN jsonb_build_object('status', 'unchanged', 'version', v_version);
  END IF;

  PERFORM set_config('jlproject.hierarchy_operation_id', p_operation_id::text, true);
  PERFORM set_config('jlproject.hierarchy_actor_id', p_actor_id::text, true);

  IF p_kind = 'discipline' THEN
    UPDATE public.product_disciplines AS item SET
      display_order = ordering.ordinality - 1, version = item.version + 1,
      updated_by = p_actor_id, updated_at = clock_timestamp()
    FROM jsonb_array_elements_text(v_source_after) WITH ORDINALITY AS ordering(id, ordinality)
    WHERE item.workspace_id = p_workspace_id AND item.product_id = p_product_id
      AND item.id = ordering.id::uuid AND item.deleted_at IS NULL
      AND item.display_order <> ordering.ordinality - 1;
  ELSIF p_kind = 'stage' THEN
    SET CONSTRAINTS public.stage_activities_parent_fk DEFERRED;
    IF NOT v_same_parent THEN
      UPDATE public.discipline_stages AS item SET
        display_order = ordering.ordinality - 1, version = item.version + 1,
        updated_by = p_actor_id, updated_at = clock_timestamp()
      FROM jsonb_array_elements_text(v_source_after) WITH ORDINALITY AS ordering(id, ordinality)
      WHERE item.workspace_id = p_workspace_id AND item.product_id = p_product_id
        AND item.discipline_id = v_original_discipline_id AND item.id = ordering.id::uuid
        AND item.deleted_at IS NULL AND item.display_order <> ordering.ordinality - 1;
    END IF;
    UPDATE public.discipline_stages AS item SET
      discipline_id = CASE WHEN item.id = p_target_id THEN p_destination_discipline_id ELSE item.discipline_id END,
      display_order = ordering.ordinality - 1, version = item.version + 1,
      updated_by = p_actor_id, updated_at = clock_timestamp()
    FROM jsonb_array_elements_text(v_destination_after) WITH ORDINALITY AS ordering(id, ordinality)
    WHERE item.workspace_id = p_workspace_id AND item.product_id = p_product_id
      AND item.id = ordering.id::uuid AND item.deleted_at IS NULL
      AND (item.display_order <> ordering.ordinality - 1 OR
        (item.id = p_target_id AND item.discipline_id <> p_destination_discipline_id));
    IF NOT v_same_parent THEN
      SELECT COALESCE(jsonb_agg(id::text ORDER BY id), '[]'::jsonb) INTO v_descendants
      FROM public.stage_activities
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND stage_id = p_target_id;
      UPDATE public.stage_activities SET discipline_id = p_destination_discipline_id,
        version = version + 1, updated_by = p_actor_id, updated_at = clock_timestamp()
      WHERE workspace_id = p_workspace_id AND product_id = p_product_id AND stage_id = p_target_id;
    END IF;
  ELSE
    IF NOT v_same_parent THEN
      UPDATE public.stage_activities AS item SET
        display_order = ordering.ordinality - 1, version = item.version + 1,
        updated_by = p_actor_id, updated_at = clock_timestamp()
      FROM jsonb_array_elements_text(v_source_after) WITH ORDINALITY AS ordering(id, ordinality)
      WHERE item.workspace_id = p_workspace_id AND item.product_id = p_product_id
        AND item.discipline_id IS NOT DISTINCT FROM v_original_discipline_id
        AND item.stage_id IS NOT DISTINCT FROM v_original_stage_id
        AND item.id = ordering.id::uuid AND item.deleted_at IS NULL
        AND item.display_order <> ordering.ordinality - 1;
    END IF;
    UPDATE public.stage_activities AS item SET
      discipline_id = CASE WHEN item.id = p_target_id THEN p_destination_discipline_id ELSE item.discipline_id END,
      stage_id = CASE WHEN item.id = p_target_id THEN p_destination_stage_id ELSE item.stage_id END,
      display_order = ordering.ordinality - 1, version = item.version + 1,
      updated_by = p_actor_id, updated_at = clock_timestamp()
    FROM jsonb_array_elements_text(v_destination_after) WITH ORDINALITY AS ordering(id, ordinality)
    WHERE item.workspace_id = p_workspace_id AND item.product_id = p_product_id
      AND item.id = ordering.id::uuid AND item.deleted_at IS NULL
      AND (item.display_order <> ordering.ordinality - 1 OR
        (item.id = p_target_id AND (item.discipline_id IS DISTINCT FROM p_destination_discipline_id OR
          item.stage_id IS DISTINCT FROM p_destination_stage_id)));
  END IF;

  IF p_kind = 'discipline' THEN
    SELECT version INTO v_version_after FROM public.product_disciplines WHERE id = p_target_id;
  ELSIF p_kind = 'stage' THEN
    SELECT version INTO v_version_after FROM public.discipline_stages WHERE id = p_target_id;
  ELSE
    SELECT version INTO v_version_after FROM public.stage_activities WHERE id = p_target_id;
  END IF;

  INSERT INTO public.hierarchy_movement_events (
    operation_id, workspace_id, product_id, item_kind, item_id, actor_id,
    original_discipline_id, original_stage_id, new_discipline_id, new_stage_id,
    original_display_order, new_display_order, version_before, version_after,
    source_order_before, source_order_after, destination_order_before,
    destination_order_after, descendant_activity_ids
  ) VALUES (
    p_operation_id, p_workspace_id, p_product_id, p_kind, p_target_id, p_actor_id,
    v_original_discipline_id, v_original_stage_id, p_destination_discipline_id,
    p_destination_stage_id, v_original_order, p_destination_index, v_version,
    v_version_after, v_source_before, v_source_after, v_destination_before,
    v_destination_after, v_descendants
  );
  RETURN jsonb_build_object('status', 'moved', 'version', v_version_after);
END;
$$;
REVOKE ALL ON FUNCTION public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)
  TO jlproject_worker;

RESET ROLE;

-- Deleted descendants remain retained and immutable except for the audited
-- ancestry rewrite required when their active stage moves disciplines.
CREATE OR REPLACE FUNCTION public.guard_schedule_deletion() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical schedule deletion is forbidden.' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NOT NULL OR OLD.deletion_operation_id IS NOT NULL THEN
      IF NOT (TG_TABLE_NAME = 'stage_activities' AND current_user = 'jlproject_date_executor'
        AND NULLIF(current_setting('jlproject.hierarchy_operation_id', true), '') IS NOT NULL
        AND NEW.discipline_id IS DISTINCT FROM OLD.discipline_id
        AND NEW.stage_id IS NOT DISTINCT FROM OLD.stage_id
        AND (to_jsonb(NEW) - ARRAY['discipline_id','version','updated_by','updated_at']) =
          (to_jsonb(OLD) - ARRAY['discipline_id','version','updated_by','updated_at'])
        AND NEW.version = OLD.version + 1
        AND NEW.updated_by::text = NULLIF(current_setting('jlproject.hierarchy_actor_id', true), '')) THEN
        RAISE EXCEPTION 'Deleted schedule items are immutable.' USING ERRCODE = '23514';
      END IF;
    END IF;
    IF (NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR
        NEW.deletion_operation_id IS DISTINCT FROM OLD.deletion_operation_id) AND
       current_user <> 'jlproject_date_executor' THEN
      RAISE EXCEPTION 'Controlled schedule deletion is required.' USING ERRCODE = '42501';
    END IF;
  ELSIF NEW.deleted_at IS NOT NULL OR NEW.deletion_operation_id IS NOT NULL THEN
    RAISE EXCEPTION 'New schedule items must be active.' USING ERRCODE = '23514';
  END IF;
  IF TG_TABLE_NAME = 'discipline_stages' THEN
    IF NOT EXISTS (SELECT 1 FROM public.product_disciplines AS d
      WHERE d.id = NEW.discipline_id AND d.workspace_id = NEW.workspace_id
        AND d.product_id = NEW.product_id AND d.deleted_at IS NULL) THEN
      RAISE EXCEPTION 'Parent discipline is inactive.' USING ERRCODE = '23514';
    END IF;
  ELSIF TG_TABLE_NAME = 'stage_activities' THEN
    IF NOT EXISTS (SELECT 1 FROM public.products AS p
      WHERE p.workspace_id = NEW.workspace_id AND p.id = NEW.product_id AND p.active = true
        AND ((NEW.discipline_id IS NULL AND NEW.stage_id IS NULL) OR EXISTS (
          SELECT 1 FROM public.discipline_stages AS s
          JOIN public.product_disciplines AS d ON d.workspace_id = s.workspace_id
            AND d.product_id = s.product_id AND d.id = s.discipline_id
          WHERE s.id = NEW.stage_id AND s.workspace_id = NEW.workspace_id
            AND s.product_id = NEW.product_id AND s.discipline_id = NEW.discipline_id
            AND s.deleted_at IS NULL AND d.deleted_at IS NULL))) THEN
      RAISE EXCEPTION 'Parent product or stage is inactive.' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_schedule_deletion() FROM PUBLIC;

-- Existing metadata endpoints must no longer be an unaudited ordering bypass.
REVOKE UPDATE (display_order) ON public.product_disciplines FROM jlproject_worker;
REVOKE UPDATE (display_order) ON public.discipline_stages FROM jlproject_worker;
REVOKE UPDATE (display_order) ON public.stage_activities FROM jlproject_worker;

CREATE OR REPLACE FUNCTION public.update_discipline_stage(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_actor_id uuid, p_code text, p_color text, p_display_name text,
  p_display_order integer, p_version bigint
) RETURNS text
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
DECLARE v_definition_id uuid; v_color text; v_version bigint; v_display_order integer;
BEGIN
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  SELECT stage.version, stage.display_order INTO v_version, v_display_order
  FROM public.discipline_stages AS stage
  JOIN public.products AS product ON product.id = stage.product_id
  WHERE stage.id = p_stage_id AND stage.workspace_id = p_workspace_id
    AND stage.product_id = p_product_id AND stage.discipline_id = p_discipline_id
    AND stage.deleted_at IS NULL AND product.active = true FOR UPDATE OF stage;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  IF v_version <> p_version OR v_display_order <> p_display_order THEN RETURN 'stale'; END IF;
  SELECT id, color INTO v_definition_id, v_color FROM public.stage_definitions
    WHERE workspace_id = p_workspace_id AND lower(code) = lower(p_code);
  IF FOUND THEN
    IF v_color <> p_color THEN RETURN 'conflict'; END IF;
  ELSE
    INSERT INTO public.stage_definitions (workspace_id, code, color)
      VALUES (p_workspace_id, p_code, p_color) RETURNING id INTO v_definition_id;
  END IF;
  IF EXISTS (SELECT 1 FROM public.discipline_stages
    WHERE discipline_id = p_discipline_id AND definition_id = v_definition_id AND id <> p_stage_id) THEN
    RETURN 'duplicate';
  END IF;
  UPDATE public.discipline_stages SET definition_id = v_definition_id,
    display_name = p_display_name, updated_by = p_actor_id,
    updated_at = now(), version = version + 1 WHERE id = p_stage_id;
  RETURN 'updated';
END;
$$;
REVOKE ALL ON FUNCTION public.update_discipline_stage(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,bigint)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_discipline_stage(uuid,uuid,uuid,uuid,uuid,text,text,text,integer,bigint)
  TO jlproject_worker;

REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
-- Remove only the temporary membership row granted by this migration, leaving
-- the pre-existing administrative membership and its options intact.
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND conname = 'stage_activities_parent_fk' AND contype = 'f' AND condeferrable) OR
     EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_activity_fk') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.activity_date_changes'::regclass
       AND conname = 'activity_date_changes_product_scope_fk' AND contype = 'f') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.hierarchy_movement_events'::regclass) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT has_function_privilege('jlproject_worker',
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'INSERT') OR
     has_column_privilege('jlproject_worker', 'public.product_disciplines', 'display_order', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.discipline_stages', 'display_order', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'display_order', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'discipline_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'stage_id', 'UPDATE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     (SELECT count(*) <> 1 OR NOT bool_and(membership.admin_option AND
       NOT membership.inherit_option AND NOT membership.set_option)
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
       WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Hierarchy movement postconditions or least-privilege boundaries are incorrect.';
  END IF;
END;
$$;

COMMIT;
