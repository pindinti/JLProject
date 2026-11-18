BEGIN;

DO $preflight$
DECLARE
  v_constraint text;
  v_provenance oid := to_regprocedure('public.link_product_schedule_history_provenance()');
  v_history oid := to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)');
BEGIN
  SELECT pg_get_constraintdef(oid, true) INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.product_schedule_operation_source_events'::regclass
    AND conname = 'product_schedule_operation_source_events_source_ledger_check'
    AND contype = 'c';

  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     v_constraint IS DISTINCT FROM
       'CHECK (source_ledger = ANY (ARRAY[' ||
       '''activity_date_changes''::text, ''stage_date_changes''::text, ' ||
       '''business_target_date_changes''::text, ''calendar_reschedule_changes''::text, ' ||
       '''calendar_reschedule_reversals''::text, ''hierarchy_movement_events''::text, ' ||
       '''schedule_deletion_events''::text]))' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.product_schedule_operation_source_events'::regclass)
       <> 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE
       tgrelid = 'public.product_schedule_operation_source_events'::regclass
       AND tgname = 'product_schedule_operation_source_events_append_only'
       AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger WHERE
       tgrelid = 'public.product_schedule_operation_source_events'::regclass
       AND tgname = 'product_schedule_operation_source_events_no_truncate'
       AND tgenabled IN ('O', 'A')) OR
     v_provenance IS NULL OR v_history IS NULL OR
     pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = v_provenance))
       <> 'jlproject_date_executor' OR
     NOT (SELECT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
       FROM pg_proc WHERE oid = v_provenance) OR
     position('v_source_ledger := ''products''' IN pg_get_functiondef(v_provenance)) = 0 OR
     position('v_source_ledger := ''import_batches''' IN pg_get_functiondef(v_provenance)) = 0 OR
     position('source.source_ledger = ''products''' IN pg_get_functiondef(v_history)) = 0 OR
     position('source.source_ledger = ''import_batches''' IN pg_get_functiondef(v_history)) = 0 OR
     (SELECT count(*) FROM pg_trigger WHERE tgname IN
       ('products_z_history_source_link', 'import_batches_z_history_source_link')
       AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred) <> 2 OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'INSERT') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'SELECT') THEN
    RAISE EXCEPTION 'Development migration 0033 prerequisites or source-type contract differ.';
  END IF;
END;
$preflight$;

GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;

ALTER TABLE public.product_schedule_operation_source_events
  DROP CONSTRAINT product_schedule_operation_source_events_source_ledger_check;
ALTER TABLE public.product_schedule_operation_source_events
  ADD CONSTRAINT product_schedule_operation_source_events_source_ledger_check
  CHECK (source_ledger IN (
    'activity_date_changes', 'stage_date_changes', 'business_target_date_changes',
    'calendar_reschedule_changes', 'calendar_reschedule_reversals',
    'hierarchy_movement_events', 'schedule_deletion_events',
    'products', 'import_batches'
  ));

RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $postflight$
DECLARE
  v_constraint text;
BEGIN
  SELECT pg_get_constraintdef(oid, true) INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.product_schedule_operation_source_events'::regclass
    AND conname = 'product_schedule_operation_source_events_source_ledger_check'
    AND contype = 'c';

  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner' OR
     v_constraint IS DISTINCT FROM
       'CHECK (source_ledger = ANY (ARRAY[' ||
       '''activity_date_changes''::text, ''stage_date_changes''::text, ' ||
       '''business_target_date_changes''::text, ''calendar_reschedule_changes''::text, ' ||
       '''calendar_reschedule_reversals''::text, ''hierarchy_movement_events''::text, ' ||
       '''schedule_deletion_events''::text, ''products''::text, ''import_batches''::text]))' OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'INSERT') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'SELECT') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.product_schedule_operation_source_events'::regclass)
       <> 'jlproject_date_executor' OR
     (SELECT count(*) FROM pg_trigger WHERE
       tgrelid = 'public.product_schedule_operation_source_events'::regclass
       AND tgname IN ('product_schedule_operation_source_events_append_only',
         'product_schedule_operation_source_events_no_truncate')
       AND tgenabled IN ('O', 'A')) <> 2 THEN
    RAISE EXCEPTION 'Migration 0033 postconditions failed.';
  END IF;
END;
$postflight$;

COMMIT;
