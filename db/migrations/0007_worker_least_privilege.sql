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

GRANT CONNECT ON DATABASE neondb TO jlproject_worker;
GRANT USAGE ON SCHEMA public, neon_auth TO jlproject_worker;
GRANT SELECT (id, name, email) ON neon_auth."user" TO jlproject_worker;
GRANT SELECT ON public.workspaces, public.workspace_memberships, public.products,
  public.product_disciplines, public.stage_definitions, public.discipline_stages,
  public.stage_activities, public.business_targets, public.import_batches,
  public.import_source_rows, public.initial_schedule_revisions TO jlproject_worker;

-- The existing SECURITY INVOKER functions lock workspace rows with FOR UPDATE.
GRANT UPDATE (name) ON public.workspaces TO jlproject_worker;
GRANT UPDATE (role, active) ON public.workspace_memberships TO jlproject_worker;
GRANT INSERT ON public.products, public.product_disciplines, public.stage_definitions,
  public.discipline_stages, public.stage_activities, public.business_targets,
  public.import_batches, public.import_source_rows, public.initial_schedule_revisions
  TO jlproject_worker;
GRANT UPDATE (name, description, active, updated_by, updated_at, version)
  ON public.products TO jlproject_worker;
GRANT UPDATE (name, short_code, color, display_order, description, updated_by, updated_at, version)
  ON public.product_disciplines TO jlproject_worker;
GRANT UPDATE (definition_id, display_name, display_order, updated_by, updated_at, version)
  ON public.discipline_stages TO jlproject_worker;
GRANT UPDATE (name, activity_type, display_order, notes, updated_by, updated_at, version)
  ON public.stage_activities TO jlproject_worker;

GRANT EXECUTE ON FUNCTION public.update_workspace_membership(uuid, uuid, uuid, text, boolean),
  public.create_discipline_stage(uuid, uuid, uuid, uuid, text, text, text, integer),
  public.update_discipline_stage(uuid, uuid, uuid, uuid, uuid, text, text, text, integer, bigint),
  public.import_initial_schedule(uuid, uuid, uuid, text, text, jsonb)
  TO jlproject_worker;

-- The executor owns the audited operation and ledger. The temporary grant permits
-- the migration owner to grant only EXECUTE and SELECT, then is removed.
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;
GRANT EXECUTE ON FUNCTION public.change_activity_dates(uuid, uuid, uuid, uuid, uuid, uuid, uuid,
  date, date, text, bigint) TO jlproject_worker;
GRANT SELECT ON public.activity_date_changes TO jlproject_worker;
RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
BEGIN
  IF pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.change_activity_dates(uuid,uuid,uuid,uuid,uuid,uuid,uuid,date,date,text,bigint)',
       'execute') OR
     NOT has_table_privilege('jlproject_worker', 'public.activity_date_changes', 'select') OR
     has_table_privilege('jlproject_worker', 'public.activity_date_changes', 'insert') OR
     has_table_privilege('jlproject_worker', 'public.activity_date_changes', 'update') OR
     has_table_privilege('jlproject_worker', 'public.activity_date_changes', 'delete') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'update') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'update') THEN
    RAISE EXCEPTION 'The Worker role must not bypass the audited date operation.';
  END IF;
END;
$$;

COMMIT;
