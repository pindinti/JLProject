BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'jlproject_date_executor' AND rolcanlogin = false
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'jlproject_calendar_executor' AND rolcanlogin = false
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    JOIN pg_roles AS owner_role ON owner_role.oid = relation.relowner
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'workspace_calendar_versions'
      AND owner_role.rolname = 'jlproject_calendar_executor'
  ) OR has_table_privilege(
    'jlproject_date_executor', 'public.workspace_calendar_versions', 'SELECT'
  ) THEN
    RAISE EXCEPTION 'Apply this migration once with the reviewed JLProject development roles.';
  END IF;
END;
$$;

-- The calendar executor owns the version table. Membership is temporary so the
-- owner can grant only the read capability required by the date executor.
GRANT jlproject_calendar_executor TO neondb_owner;
SET ROLE jlproject_calendar_executor;
GRANT SELECT ON public.workspace_calendar_versions TO jlproject_date_executor;
RESET ROLE;
REVOKE jlproject_calendar_executor FROM neondb_owner;

DO $$
BEGIN
  IF NOT has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'SELECT'
     ) OR has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'INSERT'
     ) OR has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'UPDATE'
     ) OR has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'DELETE'
     ) OR has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'TRUNCATE'
     ) OR has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'REFERENCES'
     ) OR has_table_privilege(
       'jlproject_date_executor', 'public.workspace_calendar_versions', 'TRIGGER'
     ) OR EXISTS (
       SELECT 1 FROM pg_roles
       WHERE rolname = 'jlproject_date_executor' AND rolcanlogin = true
     ) OR pg_has_role('neondb_owner', 'jlproject_calendar_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_calendar_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_calendar_executor', 'member') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Date executor calendar-read privileges are not correctly restricted.';
  END IF;
END;
$$;

COMMIT;
