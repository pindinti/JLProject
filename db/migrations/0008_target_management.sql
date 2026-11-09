BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin = true
  ) THEN
    RAISE EXCEPTION 'Apply this migration using the reviewed JLProject development roles.';
  END IF;
END;
$$;

ALTER TABLE public.business_targets
  ALTER COLUMN source_external_id DROP NOT NULL,
  ALTER COLUMN source_row DROP NOT NULL,
  DROP CONSTRAINT business_targets_source_external_id_check,
  DROP CONSTRAINT business_targets_source_row_check,
  ADD CONSTRAINT business_targets_source_external_id_check
    CHECK (source_external_id IS NULL OR source_external_id ~ '^T[0-9]{3}$'),
  ADD CONSTRAINT business_targets_source_row_check
    CHECK (source_row IS NULL OR source_row BETWEEN 4 AND 8),
  ADD COLUMN description text CHECK (description IS NULL OR char_length(description) <= 2000),
  ADD COLUMN color text NOT NULL DEFAULT '#AA4557' CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
  ADD COLUMN deleted_at timestamptz,
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);

DROP INDEX public.business_targets_name_unique_idx;
CREATE UNIQUE INDEX business_targets_name_unique_idx
  ON public.business_targets (product_id, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE public.business_target_date_changes (
  operation_id uuid PRIMARY KEY,
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  target_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  previous_date date NOT NULL,
  new_date date NOT NULL,
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 10 AND 2000 AND
    reason = btrim(reason) AND reason !~ '[[:cntrl:]]'),
  version_before bigint NOT NULL CHECK (version_before > 0),
  version_after bigint NOT NULL CHECK (version_after = version_before + 1),
  FOREIGN KEY (workspace_id, product_id, target_id)
    REFERENCES public.business_targets(workspace_id, product_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, actor_id)
    REFERENCES public.workspace_memberships(workspace_id, auth_user_id) ON DELETE RESTRICT,
  CHECK (previous_date <> new_date),
  UNIQUE (target_id, version_after)
);
CREATE INDEX business_target_date_changes_history_idx
  ON public.business_target_date_changes (workspace_id, product_id, target_id, changed_at DESC);
REVOKE ALL ON public.business_target_date_changes FROM PUBLIC;

CREATE FUNCTION public.prevent_business_target_date_change_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'Target date history is append-only.' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER business_target_date_changes_immutable
  BEFORE UPDATE OR DELETE ON public.business_target_date_changes
  FOR EACH ROW EXECUTE FUNCTION public.prevent_business_target_date_change_mutation();
REVOKE ALL ON FUNCTION public.prevent_business_target_date_change_mutation() FROM PUBLIC;

CREATE FUNCTION public.prevent_business_target_date_update()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_operation text; v_reason text; v_actor text;
BEGIN
  IF NEW.target_date IS NOT DISTINCT FROM OLD.target_date THEN RETURN NEW; END IF;
  IF current_user <> 'jlproject_date_executor' THEN
    RAISE EXCEPTION 'An audited target date operation is required.' USING ERRCODE = '23514';
  END IF;
  v_operation := NULLIF(current_setting('jlproject.target_operation_id', true), '');
  v_reason := NULLIF(current_setting('jlproject.target_change_reason', true), '');
  v_actor := NULLIF(current_setting('jlproject.target_actor_id', true), '');
  IF v_operation IS NULL OR v_reason IS NULL OR v_actor IS NULL OR
     NEW.version <> OLD.version + 1 THEN
    RAISE EXCEPTION 'An audited target date operation is required.' USING ERRCODE = '23514';
  END IF;
  INSERT INTO public.business_target_date_changes (operation_id, workspace_id, product_id,
    target_id, actor_id, previous_date, new_date, reason, version_before, version_after)
  VALUES (v_operation::uuid, OLD.workspace_id, OLD.product_id, OLD.id, v_actor::uuid,
    OLD.target_date, NEW.target_date, v_reason, OLD.version, NEW.version);
  RETURN NEW;
END;
$$;
CREATE TRIGGER business_targets_audit_date_update BEFORE UPDATE OF target_date
  ON public.business_targets FOR EACH ROW EXECUTE FUNCTION public.prevent_business_target_date_update();
REVOKE ALL ON FUNCTION public.prevent_business_target_date_update() FROM PUBLIC;

CREATE FUNCTION public.update_business_target(
  p_workspace_id uuid, p_product_id uuid, p_target_id uuid, p_actor_id uuid,
  p_operation_id uuid, p_name text, p_description text, p_color text,
  p_target_date date, p_expected_version bigint, p_reason text
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_target public.business_targets%ROWTYPE; v_reason text;
BEGIN
  IF p_operation_id IS NULL OR p_name IS NULL OR char_length(btrim(p_name)) NOT BETWEEN 1 AND 200 OR
     p_description IS NOT NULL AND char_length(p_description) > 2000 OR
     p_color IS NULL OR p_color !~ '^#[0-9A-Fa-f]{6}$' OR p_target_date IS NULL OR
     p_expected_version IS NULL OR p_expected_version < 1 THEN RETURN 'invalid'; END IF;
  PERFORM 1 FROM public.workspace_memberships WHERE workspace_id = p_workspace_id
    AND auth_user_id = p_actor_id AND active AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN 'forbidden'; END IF;
  SELECT target.* INTO v_target FROM public.business_targets AS target
    JOIN public.products AS product ON product.workspace_id = target.workspace_id
      AND product.id = target.product_id
    WHERE target.workspace_id = p_workspace_id AND target.product_id = p_product_id
      AND target.id = p_target_id AND target.deleted_at IS NULL AND product.active
    FOR UPDATE OF target;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  IF v_target.version <> p_expected_version THEN RETURN 'stale'; END IF;
  IF v_target.target_date IS DISTINCT FROM p_target_date THEN
    v_reason := btrim(p_reason);
    IF v_reason IS NULL OR char_length(v_reason) NOT BETWEEN 10 AND 2000 OR
       v_reason ~ '[[:cntrl:]]' THEN RETURN 'invalid'; END IF;
    PERFORM set_config('jlproject.target_operation_id', p_operation_id::text, true);
    PERFORM set_config('jlproject.target_change_reason', v_reason, true);
    PERFORM set_config('jlproject.target_actor_id', p_actor_id::text, true);
  END IF;
  UPDATE public.business_targets SET name = btrim(p_name), description = p_description,
    color = upper(p_color), target_date = p_target_date, version = version + 1
    WHERE id = p_target_id;
  RETURN 'updated';
END;
$$;

CREATE FUNCTION public.delete_business_target(
  p_workspace_id uuid, p_product_id uuid, p_target_id uuid, p_actor_id uuid,
  p_operation_id uuid, p_expected_version bigint
) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_target public.business_targets%ROWTYPE;
BEGIN
  IF p_operation_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN RETURN 'invalid'; END IF;
  PERFORM 1 FROM public.workspace_memberships WHERE workspace_id = p_workspace_id
    AND auth_user_id = p_actor_id AND active AND role IN ('admin', 'editor') FOR SHARE;
  IF NOT FOUND THEN RETURN 'forbidden'; END IF;
  SELECT target.* INTO v_target FROM public.business_targets AS target
    JOIN public.products AS product ON product.workspace_id = target.workspace_id
      AND product.id = target.product_id
    WHERE target.workspace_id = p_workspace_id AND target.product_id = p_product_id
      AND target.id = p_target_id AND target.deleted_at IS NULL AND product.active
    FOR UPDATE OF target;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;
  IF v_target.version <> p_expected_version THEN RETURN 'stale'; END IF;
  UPDATE public.business_targets SET deleted_at = clock_timestamp(), version = version + 1
    WHERE id = p_target_id;
  RETURN 'deleted';
END;
$$;
REVOKE ALL ON FUNCTION public.update_business_target(uuid, uuid, uuid, uuid, uuid, text, text,
  text, date, bigint, text), public.delete_business_target(uuid, uuid, uuid, uuid, uuid, bigint) FROM PUBLIC;

GRANT SELECT ON public.business_targets, public.workspace_memberships, public.products TO jlproject_date_executor;
GRANT UPDATE (name, description, color, target_date, version, deleted_at) ON public.business_targets TO jlproject_date_executor;
GRANT INSERT ON public.business_target_date_changes TO jlproject_date_executor;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
ALTER TABLE public.business_target_date_changes OWNER TO jlproject_date_executor;
ALTER FUNCTION public.prevent_business_target_date_change_mutation() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.prevent_business_target_date_update() OWNER TO jlproject_date_executor;
ALTER FUNCTION public.update_business_target(uuid, uuid, uuid, uuid, uuid, text, text,
  text, date, bigint, text) OWNER TO jlproject_date_executor;
ALTER FUNCTION public.delete_business_target(uuid, uuid, uuid, uuid, uuid, bigint) OWNER TO jlproject_date_executor;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

GRANT INSERT (workspace_id, product_id, name, target_date, source_external_id, source_row,
  display_order, created_by, description, color) ON public.business_targets TO jlproject_worker;

GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;
GRANT EXECUTE ON FUNCTION public.update_business_target(uuid, uuid, uuid, uuid, uuid,
  text, text, text, date, bigint, text), public.delete_business_target(uuid, uuid, uuid, uuid, uuid, bigint)
  TO jlproject_worker;
GRANT SELECT ON public.business_target_date_changes TO jlproject_worker;
RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_column_privilege('jlproject_worker', 'public.business_targets', 'target_date', 'update') OR
     has_table_privilege('jlproject_worker', 'public.business_target_date_changes', 'insert') OR
     has_table_privilege('jlproject_worker', 'public.business_target_date_changes', 'update') OR
     NOT has_function_privilege('jlproject_worker',
       'public.update_business_target(uuid,uuid,uuid,uuid,uuid,text,text,text,date,bigint,text)', 'execute') THEN
    RAISE EXCEPTION 'The Worker must use the controlled audited target operation.';
  END IF;
END;
$$;

COMMIT;
