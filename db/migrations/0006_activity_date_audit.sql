BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION 'Apply this migration with the reviewed JLProject development owner role.';
  END IF;
END;
$$;
CREATE ROLE jlproject_date_executor NOLOGIN NOINHERIT;
GRANT USAGE, CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
GRANT SELECT ON public.workspace_memberships, public.products, public.stage_activities
  TO jlproject_date_executor;
GRANT UPDATE (active) ON public.workspace_memberships TO jlproject_date_executor;
GRANT UPDATE (planned_start, planned_end, version, updated_by, updated_at)
  ON public.stage_activities TO jlproject_date_executor;

ALTER TABLE public.stage_activities
  ADD CONSTRAINT stage_activities_scope_id_unique
  UNIQUE (workspace_id, product_id, discipline_id, stage_id, id);

CREATE TABLE public.activity_date_changes (
  operation_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  discipline_id uuid NOT NULL,
  stage_id uuid NOT NULL,
  activity_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  previous_start date,
  previous_end date,
  new_start date NOT NULL,
  new_end date NOT NULL,
  reason text NOT NULL CHECK (
    char_length(reason) BETWEEN 10 AND 2000 AND reason = btrim(reason)
    AND reason !~ '[[:cntrl:]]'
  ),
  version_before bigint NOT NULL CHECK (version_before > 0),
  version_after bigint NOT NULL CHECK (version_after = version_before + 1),
  CONSTRAINT activity_date_changes_activity_fk
    FOREIGN KEY (workspace_id, product_id, discipline_id, stage_id, activity_id)
    REFERENCES public.stage_activities(workspace_id, product_id, discipline_id, stage_id, id)
    ON DELETE RESTRICT,
  CONSTRAINT activity_date_changes_actor_fk
    FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id)
    ON DELETE RESTRICT,
  CONSTRAINT activity_date_changes_previous_pair_check CHECK (
    (previous_start IS NULL AND previous_end IS NULL) OR
    (previous_start IS NOT NULL AND previous_end IS NOT NULL AND previous_start <= previous_end)
  ),
  CONSTRAINT activity_date_changes_new_range_check CHECK (new_start <= new_end),
  CONSTRAINT activity_date_changes_actual_change_check CHECK (
    previous_start IS DISTINCT FROM new_start OR previous_end IS DISTINCT FROM new_end
  ),
  CONSTRAINT activity_date_changes_activity_version_unique UNIQUE (activity_id, version_after)
);
CREATE INDEX activity_date_changes_history_idx
  ON public.activity_date_changes (workspace_id, product_id, activity_id, changed_at DESC, operation_id DESC);
REVOKE ALL ON public.activity_date_changes FROM PUBLIC;
GRANT SELECT ON public.activity_date_changes TO neondb_owner;

CREATE FUNCTION public.prevent_activity_date_change_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Activity date history is append-only.' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER activity_date_changes_append_only
  BEFORE UPDATE OR DELETE ON public.activity_date_changes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_activity_date_change_mutation();
REVOKE ALL ON FUNCTION public.prevent_activity_date_change_mutation() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.prevent_activity_date_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_operation text;
  v_reason text;
  v_actor text;
BEGIN
  IF NEW.planned_start IS NOT DISTINCT FROM OLD.planned_start AND
     NEW.planned_end IS NOT DISTINCT FROM OLD.planned_end THEN
    RETURN NEW;
  END IF;

  IF current_user <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'An audited date operation is required.' USING ERRCODE = '23514';
  END IF;

  v_operation := NULLIF(current_setting('jlproject.date_operation_id', true), '');
  v_reason := NULLIF(current_setting('jlproject.date_change_reason', true), '');
  v_actor := NULLIF(current_setting('jlproject.date_actor_id', true), '');
  IF v_operation IS NULL OR v_reason IS NULL OR v_actor IS NULL OR
     NEW.updated_by::text <> v_actor OR NEW.version <> OLD.version + 1 OR
     NEW.planned_start IS NULL OR NEW.planned_end IS NULL THEN
    RAISE EXCEPTION 'An audited date operation is required.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.activity_date_changes (
    operation_id, workspace_id, product_id, discipline_id, stage_id, activity_id,
    actor_id, previous_start, previous_end, new_start, new_end, reason,
    version_before, version_after
  ) VALUES (
    v_operation::uuid, OLD.workspace_id, OLD.product_id, OLD.discipline_id, OLD.stage_id,
    OLD.id, v_actor::uuid, OLD.planned_start, OLD.planned_end,
    NEW.planned_start, NEW.planned_end, v_reason, OLD.version, NEW.version
  );
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_activity_date_update() FROM PUBLIC;

CREATE FUNCTION public.change_activity_dates(
  p_workspace_id uuid, p_product_id uuid, p_discipline_id uuid, p_stage_id uuid,
  p_activity_id uuid, p_actor_id uuid, p_operation_id uuid,
  p_start date, p_end date, p_reason text, p_expected_version bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_activity public.stage_activities%ROWTYPE;
  v_reason text;
BEGIN
  IF p_operation_id IS NULL OR p_start IS NULL OR p_end IS NULL OR p_start > p_end OR
     p_expected_version IS NULL OR p_expected_version < 1 THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'forbidden'); END IF;

  SELECT activity.* INTO v_activity
    FROM public.stage_activities AS activity
    JOIN public.products AS product
      ON product.workspace_id = activity.workspace_id AND product.id = activity.product_id
    WHERE activity.workspace_id = p_workspace_id AND activity.product_id = p_product_id
      AND activity.discipline_id = p_discipline_id AND activity.stage_id = p_stage_id
      AND activity.id = p_activity_id AND product.active = true
    FOR UPDATE OF activity;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_activity.version <> p_expected_version THEN
    RETURN jsonb_build_object('status', 'stale');
  END IF;
  IF v_activity.planned_start IS NOT DISTINCT FROM p_start AND
     v_activity.planned_end IS NOT DISTINCT FROM p_end THEN
    RETURN jsonb_build_object('status', 'unchanged');
  END IF;

  v_reason := btrim(p_reason);
  IF v_reason IS NULL OR char_length(v_reason) NOT BETWEEN 10 AND 2000 OR
     v_reason ~ '[[:cntrl:]]' THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  PERFORM set_config('jlproject.date_operation_id', p_operation_id::text, true);
  PERFORM set_config('jlproject.date_change_reason', v_reason, true);
  PERFORM set_config('jlproject.date_actor_id', p_actor_id::text, true);
  UPDATE public.stage_activities
    SET planned_start = p_start, planned_end = p_end, version = version + 1,
      updated_by = p_actor_id, updated_at = clock_timestamp()
    WHERE id = p_activity_id;
  RETURN jsonb_build_object('status', 'updated');
END;
$$;
REVOKE ALL ON FUNCTION public.change_activity_dates(uuid, uuid, uuid, uuid, uuid, uuid, uuid,
  date, date, text, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_activity_dates(uuid, uuid, uuid, uuid, uuid, uuid, uuid,
  date, date, text, bigint) TO neondb_owner;
GRANT EXECUTE ON FUNCTION public.prevent_activity_date_update() TO neondb_owner;

ALTER TABLE public.activity_date_changes OWNER TO jlproject_date_executor;
ALTER FUNCTION public.prevent_activity_date_change_mutation() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.prevent_activity_date_update() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.change_activity_dates(uuid, uuid, uuid, uuid, uuid, uuid, uuid,
  date, date, text, bigint) OWNER TO jlproject_date_executor;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') THEN
    RAISE EXCEPTION 'The application owner must not use the date executor role.';
  END IF;
END;
$$;

COMMIT;
