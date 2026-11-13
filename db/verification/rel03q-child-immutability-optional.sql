-- REL-03Q: optional rollback-only trigger check if neondb_owner already has UPDATE.
-- Never grant privileges or switch roles to make this test run.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
DO $$
DECLARE v_rejected boolean := false;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'neondb_owner' OR
     NOT has_table_privilege(current_user,
       'public.hierarchy_movement_events', 'UPDATE') THEN
    RAISE EXCEPTION 'Existing owner UPDATE permission is required; do not grant it.';
  END IF;
  BEGIN
    UPDATE public.hierarchy_movement_events
       SET new_display_order = new_display_order
     WHERE operation_id = '7c000000-0000-4000-8000-000000000101';
  EXCEPTION WHEN SQLSTATE '23514' THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Movement audit immutability trigger did not reject UPDATE.';
  END IF;
  RAISE NOTICE 'REL-03Q movement ledger UPDATE rejected with SQLSTATE 23514.';
END;
$$;
ROLLBACK;
