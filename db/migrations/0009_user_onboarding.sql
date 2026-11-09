BEGIN;

CREATE FUNCTION public.add_workspace_membership(
  p_actor_id uuid,
  p_workspace_id uuid,
  p_new_user_id uuid,
  p_role text
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
BEGIN
  -- Serialize member changes with the existing administration function.
  PERFORM 1 FROM public.workspaces WHERE id = p_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'denied'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.workspace_memberships
    WHERE workspace_id = p_workspace_id AND auth_user_id = p_actor_id
      AND role = 'admin' AND active = true
  ) THEN RETURN 'denied'; END IF;

  IF p_role NOT IN ('admin', 'editor', 'viewer') OR p_role IS NULL THEN RETURN 'denied'; END IF;
  IF NOT EXISTS (SELECT 1 FROM neon_auth."user" WHERE id = p_new_user_id) THEN
    RETURN 'missing_user';
  END IF;

  INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
  VALUES (p_workspace_id, p_new_user_id, p_role, true)
  ON CONFLICT (workspace_id, auth_user_id) DO NOTHING;
  IF NOT FOUND THEN RETURN 'duplicate'; END IF;
  RETURN 'added';
END;
$$;

REVOKE ALL ON FUNCTION public.add_workspace_membership(uuid, uuid, uuid, text) FROM PUBLIC;
GRANT INSERT ON public.workspace_memberships TO jlproject_worker;
GRANT EXECUTE ON FUNCTION public.add_workspace_membership(uuid, uuid, uuid, text) TO jlproject_worker;

COMMIT;
