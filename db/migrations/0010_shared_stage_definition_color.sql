BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin = true
      AND rolsuper = false AND rolcreaterole = false AND rolcreatedb = false
  ) OR pg_has_role('jlproject_worker', 'neon_superuser', 'member') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'The reviewed limited development Worker role is required.';
  END IF;
END;
$$;

-- The Worker may change only the shared color column. Workspace and optimistic
-- concurrency predicates are enforced by the authenticated Worker endpoint.
GRANT UPDATE (color) ON public.stage_definitions TO jlproject_worker;

COMMIT;
