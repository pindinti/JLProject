BEGIN;

DO $$
DECLARE
  v_column text;
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     NOT EXISTS (
       SELECT 1 FROM pg_roles
       WHERE rolname = 'jlproject_date_executor' AND rolcanlogin = false
     ) OR
     NOT EXISTS (
       SELECT 1 FROM pg_class AS relation
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       JOIN pg_roles AS owner_role ON owner_role.oid = relation.relowner
       WHERE namespace.nspname = 'public'
         AND relation.relname = 'discipline_stages'
         AND owner_role.rolname = 'neondb_owner'
     ) OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'SELECT') OR
     EXISTS (
       SELECT 1 FROM pg_attribute
       WHERE attrelid = 'public.discipline_stages'::regclass
         AND attnum > 0 AND NOT attisdropped
         AND attname NOT IN ('id', 'workspace_id', 'product_id', 'discipline_id')
         AND has_column_privilege(
           'jlproject_date_executor', 'public.discipline_stages', attname, 'SELECT'
         )
     ) THEN
    RAISE EXCEPTION 'Apply this migration once with the reviewed JLProject development roles.';
  END IF;

  FOREACH v_column IN ARRAY ARRAY['id', 'workspace_id', 'product_id', 'discipline_id'] LOOP
    IF has_column_privilege(
      'jlproject_date_executor', 'public.discipline_stages', v_column, 'SELECT'
    ) THEN
      RAISE EXCEPTION 'The date executor already has stage-scope read access.';
    END IF;
  END LOOP;
END;
$$;

GRANT SELECT (id, workspace_id, product_id, discipline_id)
  ON public.discipline_stages TO jlproject_date_executor;

DO $$
DECLARE
  v_column text;
BEGIN
  FOREACH v_column IN ARRAY ARRAY['id', 'workspace_id', 'product_id', 'discipline_id'] LOOP
    IF NOT has_column_privilege(
      'jlproject_date_executor', 'public.discipline_stages', v_column, 'SELECT'
    ) THEN
      RAISE EXCEPTION 'The date executor is missing a required stage-scope column.';
    END IF;
  END LOOP;

  IF has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'SELECT') OR
     EXISTS (
       SELECT 1 FROM pg_attribute
       WHERE attrelid = 'public.discipline_stages'::regclass
         AND attnum > 0 AND NOT attisdropped
         AND attname NOT IN ('id', 'workspace_id', 'product_id', 'discipline_id')
         AND has_column_privilege(
           'jlproject_date_executor', 'public.discipline_stages', attname, 'SELECT'
         )
     ) OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'INSERT') OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'UPDATE') OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'DELETE') OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'TRUNCATE') OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'REFERENCES') OR
     has_table_privilege('jlproject_date_executor', 'public.discipline_stages', 'TRIGGER') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     EXISTS (
       SELECT 1 FROM pg_roles
       WHERE rolname = 'jlproject_date_executor' AND rolcanlogin = true
     ) THEN
    RAISE EXCEPTION 'The date executor or Worker has an unexpected privilege.';
  END IF;
END;
$$;

COMMIT;
