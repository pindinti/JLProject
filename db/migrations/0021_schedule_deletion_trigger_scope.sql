BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.schedule_deletion_events') IS NULL OR
     to_regprocedure('public.guard_schedule_deletion()') IS NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc
       WHERE oid = 'public.guard_schedule_deletion()'::regprocedure) <> 'neondb_owner' THEN
    RAISE EXCEPTION 'Unexpected schedule deletion trigger migration target.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_schedule_deletion() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical schedule deletion is forbidden.' USING ERRCODE = '23514';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.deleted_at IS NOT NULL OR OLD.deletion_operation_id IS NOT NULL THEN
      RAISE EXCEPTION 'Deleted schedule items are immutable.' USING ERRCODE = '23514';
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
    IF NOT EXISTS (
      SELECT 1 FROM public.product_disciplines AS d WHERE d.id = NEW.discipline_id
        AND d.workspace_id = NEW.workspace_id AND d.product_id = NEW.product_id
        AND d.deleted_at IS NULL
    ) THEN RAISE EXCEPTION 'Parent discipline is inactive.' USING ERRCODE = '23514'; END IF;
  END IF;
  IF TG_TABLE_NAME = 'stage_activities' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.discipline_stages AS s WHERE s.id = NEW.stage_id
        AND s.workspace_id = NEW.workspace_id AND s.product_id = NEW.product_id
        AND s.discipline_id = NEW.discipline_id AND s.deleted_at IS NULL
    ) THEN RAISE EXCEPTION 'Parent stage is inactive.' USING ERRCODE = '23514'; END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_schedule_deletion() FROM PUBLIC;

DO $$
BEGIN
  IF has_function_privilege('public', 'public.guard_schedule_deletion()', 'EXECUTE') OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc
       WHERE oid = 'public.guard_schedule_deletion()'::regprocedure) <> 'neondb_owner' OR
     (SELECT count(*) FROM pg_trigger WHERE tgname IN
       ('product_disciplines_deletion_guard', 'discipline_stages_deletion_guard',
        'stage_activities_deletion_guard') AND tgenabled = 'O') <> 3 THEN
    RAISE EXCEPTION 'Schedule deletion guard privileges or triggers changed unexpectedly.';
  END IF;
END;
$$;

COMMIT;
