BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin = true
      AND rolsuper = false AND rolcreaterole = false AND rolcreatedb = false
  ) OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_calendar_executor') THEN
    RAISE EXCEPTION 'Apply this migration once with the reviewed JLProject development owner role.';
  END IF;
END;
$$;

CREATE ROLE jlproject_calendar_executor NOLOGIN NOINHERIT;
GRANT USAGE, CREATE ON SCHEMA public TO jlproject_calendar_executor;
GRANT jlproject_calendar_executor TO neondb_owner;
GRANT SELECT ON public.workspaces, public.workspace_memberships TO jlproject_calendar_executor;
-- Row locks serialize a calendar change with membership administration.
GRANT UPDATE (name) ON public.workspaces TO jlproject_calendar_executor;
GRANT UPDATE (active) ON public.workspace_memberships TO jlproject_calendar_executor;

CREATE TABLE public.workspace_calendar_versions (
  workspace_id uuid PRIMARY KEY REFERENCES public.workspaces(id) ON DELETE RESTRICT,
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE public.workspace_calendar_exceptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE RESTRICT,
  kind text NOT NULL CHECK (kind IN ('municipal_holiday', 'collective_vacation', 'company_shutdown')),
  name text,
  municipality text,
  description text,
  start_date date NOT NULL,
  end_date date NOT NULL,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by uuid NOT NULL,
  updated_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  removed_at timestamptz,
  CONSTRAINT workspace_calendar_exceptions_scope_unique UNIQUE (workspace_id, id),
  CONSTRAINT workspace_calendar_exceptions_creator_fk FOREIGN KEY (workspace_id, created_by)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT,
  CONSTRAINT workspace_calendar_exceptions_updater_fk FOREIGN KEY (workspace_id, updated_by)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT,
  CONSTRAINT workspace_calendar_exceptions_dates_check CHECK (
    start_date BETWEEN DATE '2026-01-01' AND DATE '2100-12-31' AND
    end_date BETWEEN DATE '2026-01-01' AND DATE '2100-12-31' AND
    end_date >= start_date AND end_date - start_date <= 365
  ),
  CONSTRAINT workspace_calendar_exceptions_details_check CHECK (
    (kind = 'municipal_holiday' AND start_date = end_date AND description IS NULL AND
      name IS NOT NULL AND char_length(name) BETWEEN 1 AND 200 AND name = btrim(name) AND
      name !~ '[[:cntrl:]]' AND municipality IS NOT NULL AND
      char_length(municipality) BETWEEN 1 AND 120 AND municipality = btrim(municipality) AND
      municipality !~ '[[:cntrl:]]') OR
    (kind IN ('collective_vacation', 'company_shutdown') AND name IS NULL AND municipality IS NULL AND
      description IS NOT NULL AND char_length(description) BETWEEN 1 AND 500 AND
      description = btrim(description) AND description !~ '[[:cntrl:]]')
  )
);
CREATE INDEX workspace_calendar_exceptions_active_range_idx
  ON public.workspace_calendar_exceptions (workspace_id, start_date, end_date)
  WHERE removed_at IS NULL;
CREATE UNIQUE INDEX workspace_calendar_local_unique_idx
  ON public.workspace_calendar_exceptions (workspace_id, lower(municipality), start_date)
  WHERE kind = 'municipal_holiday' AND removed_at IS NULL;

CREATE TABLE public.workspace_calendar_events (
  operation_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL REFERENCES public.workspaces(id) ON DELETE RESTRICT,
  exception_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  calendar_version bigint NOT NULL CHECK (calendar_version > 0),
  action text NOT NULL CHECK (action IN ('created', 'updated', 'removed')),
  before_state jsonb,
  after_state jsonb NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT workspace_calendar_events_exception_fk FOREIGN KEY (workspace_id, exception_id)
    REFERENCES public.workspace_calendar_exceptions(workspace_id, id) ON DELETE RESTRICT,
  CONSTRAINT workspace_calendar_events_actor_fk FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT,
  CONSTRAINT workspace_calendar_events_version_unique UNIQUE (workspace_id, calendar_version),
  CONSTRAINT workspace_calendar_events_state_check CHECK (
    (action = 'created' AND before_state IS NULL) OR
    (action IN ('updated', 'removed') AND before_state IS NOT NULL)
  )
);
CREATE INDEX workspace_calendar_events_history_idx
  ON public.workspace_calendar_events (workspace_id, calendar_version DESC);

CREATE FUNCTION public.prevent_workspace_calendar_event_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Calendar history is append-only.' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER workspace_calendar_events_append_only
  BEFORE UPDATE OR DELETE ON public.workspace_calendar_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_workspace_calendar_event_mutation();
REVOKE ALL ON FUNCTION public.prevent_workspace_calendar_event_mutation() FROM PUBLIC;

CREATE FUNCTION public.change_workspace_calendar(
  p_workspace_id uuid, p_actor_id uuid, p_operation_id uuid, p_expected_version bigint,
  p_action text, p_exception_id uuid, p_kind text, p_name text, p_municipality text,
  p_description text, p_start_date date, p_end_date date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_version bigint;
  v_before public.workspace_calendar_exceptions%ROWTYPE;
  v_after public.workspace_calendar_exceptions%ROWTYPE;
  v_name text;
  v_municipality text;
  v_description text;
  v_constraint text;
  v_action text;
BEGIN
  IF p_workspace_id IS NULL OR p_actor_id IS NULL OR p_operation_id IS NULL OR
     p_expected_version IS NULL OR p_expected_version < 0 OR
     p_action NOT IN ('create', 'update', 'remove') OR p_action IS NULL THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  IF p_action = 'remove' THEN
    IF p_exception_id IS NULL OR p_kind IS NOT NULL OR p_name IS NOT NULL OR
       p_municipality IS NOT NULL OR p_description IS NOT NULL OR
       p_start_date IS NOT NULL OR p_end_date IS NOT NULL THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
  ELSE
    v_name := NULLIF(btrim(p_name), '');
    v_municipality := NULLIF(btrim(p_municipality), '');
    v_description := NULLIF(btrim(p_description), '');
    IF p_start_date IS NULL OR p_end_date IS NULL OR
       p_start_date < DATE '2026-01-01' OR p_end_date > DATE '2100-12-31' OR
       p_end_date < p_start_date OR p_end_date - p_start_date > 365 OR
       (p_action = 'create' AND p_exception_id IS NOT NULL) OR
       (p_action = 'update' AND p_exception_id IS NULL) THEN
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
    IF p_kind = 'municipal_holiday' THEN
      IF p_start_date <> p_end_date OR v_name IS NULL OR char_length(v_name) > 200 OR
         v_name ~ '[[:cntrl:]]' OR v_municipality IS NULL OR
         char_length(v_municipality) > 120 OR v_municipality ~ '[[:cntrl:]]' OR
         p_description IS NOT NULL THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
    ELSIF p_kind IN ('collective_vacation', 'company_shutdown') THEN
      IF p_name IS NOT NULL OR p_municipality IS NOT NULL OR v_description IS NULL OR
         char_length(v_description) > 500 OR v_description ~ '[[:cntrl:]]' THEN
        RETURN jsonb_build_object('status', 'invalid');
      END IF;
    ELSE
      RETURN jsonb_build_object('status', 'invalid');
    END IF;
  END IF;

  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  PERFORM 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND active = true AND role = 'admin' FOR SHARE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'denied'); END IF;

  SELECT version INTO v_version FROM public.workspace_calendar_versions
    WHERE workspace_id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN v_version := 0; END IF;
  IF v_version <> p_expected_version THEN RETURN jsonb_build_object('status', 'stale'); END IF;

  IF p_action = 'create' THEN
    INSERT INTO public.workspace_calendar_exceptions
      (workspace_id, kind, name, municipality, description, start_date, end_date, created_by, updated_by)
    VALUES (p_workspace_id, p_kind, v_name, v_municipality, v_description,
      p_start_date, p_end_date, p_actor_id, p_actor_id)
    RETURNING * INTO v_after;
    v_action := 'created';
  ELSE
    SELECT * INTO v_before FROM public.workspace_calendar_exceptions
      WHERE workspace_id = p_workspace_id AND id = p_exception_id AND removed_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
    IF p_action = 'update' THEN
      IF v_before.kind <> p_kind THEN RETURN jsonb_build_object('status', 'invalid'); END IF;
      IF v_before.name IS NOT DISTINCT FROM v_name AND
         v_before.municipality IS NOT DISTINCT FROM v_municipality AND
         v_before.description IS NOT DISTINCT FROM v_description AND
         v_before.start_date = p_start_date AND v_before.end_date = p_end_date THEN
        RETURN jsonb_build_object('status', 'unchanged', 'version', v_version);
      END IF;
      UPDATE public.workspace_calendar_exceptions
        SET name = v_name, municipality = v_municipality, description = v_description,
          start_date = p_start_date, end_date = p_end_date, version = version + 1,
          updated_by = p_actor_id, updated_at = clock_timestamp()
        WHERE workspace_id = p_workspace_id AND id = p_exception_id
        RETURNING * INTO v_after;
      v_action := 'updated';
    ELSE
      UPDATE public.workspace_calendar_exceptions
        SET removed_at = clock_timestamp(), version = version + 1,
          updated_by = p_actor_id, updated_at = clock_timestamp()
        WHERE workspace_id = p_workspace_id AND id = p_exception_id
        RETURNING * INTO v_after;
      v_action := 'removed';
    END IF;
  END IF;

  INSERT INTO public.workspace_calendar_versions (workspace_id) VALUES (p_workspace_id)
    ON CONFLICT (workspace_id) DO NOTHING;
  UPDATE public.workspace_calendar_versions
    SET version = v_version + 1, updated_at = clock_timestamp()
    WHERE workspace_id = p_workspace_id;
  INSERT INTO public.workspace_calendar_events
    (operation_id, workspace_id, exception_id, actor_id, calendar_version,
      action, before_state, after_state)
  VALUES (p_operation_id, p_workspace_id, v_after.id, p_actor_id, v_version + 1,
    v_action, CASE WHEN v_action = 'created' THEN NULL ELSE to_jsonb(v_before) END, to_jsonb(v_after));
  RETURN jsonb_build_object('status', v_action, 'version', v_version + 1,
    'exceptionId', v_after.id);
EXCEPTION WHEN unique_violation THEN
  GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
  IF v_constraint = 'workspace_calendar_local_unique_idx' THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;
  RAISE;
END;
$$;

REVOKE ALL ON public.workspace_calendar_versions, public.workspace_calendar_exceptions,
  public.workspace_calendar_events FROM PUBLIC, jlproject_worker;
GRANT SELECT ON public.workspace_calendar_versions, public.workspace_calendar_exceptions,
  public.workspace_calendar_events TO jlproject_worker, neondb_owner;
REVOKE ALL ON FUNCTION public.change_workspace_calendar(uuid, uuid, uuid, bigint,
  text, uuid, text, text, text, text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.change_workspace_calendar(uuid, uuid, uuid, bigint,
  text, uuid, text, text, text, text, date, date) TO jlproject_worker;

ALTER TABLE public.workspace_calendar_versions OWNER TO jlproject_calendar_executor;
ALTER TABLE public.workspace_calendar_exceptions OWNER TO jlproject_calendar_executor;
ALTER TABLE public.workspace_calendar_events OWNER TO jlproject_calendar_executor;
ALTER FUNCTION public.prevent_workspace_calendar_event_mutation() OWNER TO jlproject_calendar_executor;
ALTER FUNCTION public.change_workspace_calendar(uuid, uuid, uuid, bigint,
  text, uuid, text, text, text, text, date, date) OWNER TO jlproject_calendar_executor;
REVOKE CREATE ON SCHEMA public FROM jlproject_calendar_executor;
REVOKE jlproject_calendar_executor FROM neondb_owner;

DO $$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_calendar_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_calendar_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_calendar_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.change_workspace_calendar(uuid,uuid,uuid,bigint,text,uuid,text,text,text,text,date,date)',
       'execute') OR
     has_function_privilege('public',
       'public.change_workspace_calendar(uuid,uuid,uuid,bigint,text,uuid,text,text,text,text,date,date)',
       'execute') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_exceptions', 'insert') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_exceptions', 'update') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_exceptions', 'delete') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_events', 'insert') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_events', 'update') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_events', 'delete') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_versions', 'insert') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_versions', 'update') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_versions', 'delete') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_events', 'truncate') OR
     has_table_privilege('jlproject_worker', 'public.workspace_calendar_exceptions', 'truncate') THEN
    RAISE EXCEPTION 'Calendar executor or limited Worker privileges are not correctly configured.';
  END IF;
END;
$$;

COMMIT;
