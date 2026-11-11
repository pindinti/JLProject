BEGIN;

DO $$
DECLARE
  v_clone_oid oid := to_regprocedure('public.clone_product(uuid,uuid,uuid,text)');
  v_clone_owner oid;
  v_clone_security_definer boolean;
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker'
       AND rolcanlogin = true AND rolsuper = false AND rolcreaterole = false AND rolcreatedb = false) OR
     pg_has_role('jlproject_worker', 'neon_superuser', 'member') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
       AND table_name = 'stage_activities' AND column_name = 'color_override' AND is_nullable = 'YES') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
       AND pg_get_constraintdef(oid) LIKE '%color_override%') OR
     v_clone_oid IS NULL THEN
    RAISE EXCEPTION 'Unexpected Development target, role, activity-color column, or clone function state.';
  END IF;

  SELECT proowner, prosecdef INTO v_clone_owner, v_clone_security_definer
  FROM pg_proc WHERE oid = v_clone_oid;

  IF v_clone_owner <> 'neondb_owner'::regrole OR v_clone_security_definer OR
     NOT has_function_privilege('jlproject_worker', v_clone_oid, 'EXECUTE') OR
     has_function_privilege('public', v_clone_oid, 'EXECUTE') OR
     pg_get_functiondef(v_clone_oid) NOT LIKE '%notes, color_override, created_by, updated_by%' OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'workspace_id', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'product_id', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'discipline_id', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'stage_id', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'name', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'activity_type', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'display_order', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'notes', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'created_by', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'updated_by', 'INSERT') THEN
    RAISE EXCEPTION 'The color override INSERT privilege is not the only missing clone dependency.';
  END IF;
END;
$$;

-- The SECURITY INVOKER clone inserts only this additional activity column.
GRANT INSERT (color_override) ON public.stage_activities TO jlproject_worker;

DO $$
BEGIN
  IF NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'The activity color grant expanded Worker privileges unexpectedly.';
  END IF;
END;
$$;

COMMIT;
