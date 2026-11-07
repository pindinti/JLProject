BEGIN;

CREATE FUNCTION public.update_workspace_membership(
  p_actor_id uuid,
  p_workspace_id uuid,
  p_membership_id uuid,
  p_role text,
  p_active boolean
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  current_role text;
  current_active boolean;
  target_role text;
  target_active boolean;
  active_admins integer;
BEGIN
  -- Serialize all membership changes in one workspace before checking the last administrator.
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'denied'; END IF;

  SELECT role, active INTO current_role, current_active
  FROM public.workspace_memberships
  WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id;
  IF NOT FOUND OR current_role <> 'admin' OR current_active IS NOT true THEN
    RETURN 'denied';
  END IF;

  SELECT role, active INTO target_role, target_active
  FROM public.workspace_memberships
  WHERE workspace_id = p_workspace_id AND id = p_membership_id
  FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_found'; END IF;

  IF (p_role IS NULL) = (p_active IS NULL) THEN RETURN 'invalid'; END IF;
  IF p_role IS NOT NULL AND p_role NOT IN ('admin', 'editor', 'viewer') THEN RETURN 'invalid'; END IF;

  IF target_role = 'admin' AND target_active = true
     AND (COALESCE(p_role, target_role) <> 'admin' OR COALESCE(p_active, target_active) = false) THEN
    SELECT count(*) INTO active_admins
    FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND role = 'admin' AND active = true;
    IF active_admins <= 1 THEN RETURN 'last_admin'; END IF;
  END IF;

  UPDATE public.workspace_memberships
  SET role = COALESCE(p_role, role), active = COALESCE(p_active, active)
  WHERE id = p_membership_id AND workspace_id = p_workspace_id;
  RETURN 'updated';
END;
$$;

REVOKE ALL ON FUNCTION public.update_workspace_membership(uuid, uuid, uuid, text, boolean) FROM PUBLIC;

COMMIT;
