-- REL-04: final-only read-only integrity and privilege evidence, one JSON result.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SELECT 1 / CASE WHEN current_database() = 'neondb' AND current_user = 'neondb_owner'
  AND (SELECT count(*) FROM public.products) = 5
  AND (SELECT count(*) FROM public.product_disciplines) = 19
  AND (SELECT count(*) FROM public.discipline_stages) = 40
  AND (SELECT count(*) FROM public.stage_activities) = 73
  AND (SELECT count(*) FROM public.activity_date_changes) = 3
  AND (SELECT count(*) FROM public.initial_schedule_revisions) = 1
  AND (SELECT count(*) FROM public.hierarchy_movement_events) = 0
  AND (SELECT count(*) FROM public.schedule_deletion_events) = 0
  AND NOT EXISTS (SELECT 1 FROM public.product_disciplines
    WHERE deleted_at IS NOT NULL OR deletion_operation_id IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM public.discipline_stages
    WHERE deleted_at IS NOT NULL OR deletion_operation_id IS NOT NULL)
  AND NOT EXISTS (SELECT 1 FROM public.stage_activities
    WHERE deleted_at IS NOT NULL OR deletion_operation_id IS NOT NULL)
  AND (SELECT count(*) FROM public.stage_activities WHERE discipline_id IS NULL AND stage_id IS NULL) = 0
  AND (SELECT count(*) FROM public.stage_activities WHERE color_override IS NOT NULL) = 0
  AND (SELECT count(*) FROM public.stage_activities WHERE planning_mode = 'manual'
    AND working_day_duration IS NULL AND planning_calendar_version IS NULL) = 73
  AND (SELECT count(*) FROM public.stage_activities
    WHERE (discipline_id IS NULL) <> (stage_id IS NULL)) = 0
  AND NOT EXISTS (SELECT 1 FROM public.stage_activities a
    LEFT JOIN public.products p ON p.workspace_id = a.workspace_id AND p.id = a.product_id
    WHERE p.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.stage_activities a
    LEFT JOIN public.discipline_stages s ON s.workspace_id = a.workspace_id
      AND s.product_id = a.product_id AND s.discipline_id = a.discipline_id AND s.id = a.stage_id
    WHERE a.stage_id IS NOT NULL AND s.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.discipline_stages s
    LEFT JOIN public.product_disciplines d ON d.workspace_id = s.workspace_id
      AND d.product_id = s.product_id AND d.id = s.discipline_id WHERE d.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM pg_constraint con JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
    WHERE ns.nspname = 'public' AND NOT con.convalidated)
  AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.stage_activities'::regclass
    AND conname = 'stage_activities_parent_fk' AND condeferrable AND convalidated)
  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.hierarchy_movement_events'::regclass
    AND tgname = 'hierarchy_movement_events_immutable' AND tgenabled IN ('O','A'))
  AND EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.stage_activities'::regclass
    AND tgname = 'stage_activities_deletion_guard' AND tgenabled IN ('O','A'))
  AND NOT has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT')
  AND NOT has_any_column_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT')
  AND NOT has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'INSERT')
  AND NOT has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'UPDATE')
  AND NOT has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'DELETE')
  AND has_function_privilege('jlproject_worker',
    'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('public',
    'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'EXECUTE')
  AND md5(pg_get_functiondef(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) =
    'e8d5fca15b6f0d855c133bb960047a9c'
  AND (SELECT md5(COALESCE(string_agg(jsonb_build_object('id',a.id,
    'planned_start',a.planned_start,'planned_end',a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) FROM public.stage_activities a) =
    '41276cac3ad96dcf6377af00f5b7e733'
  THEN 1 ELSE 0 END AS final_gate;
SELECT jsonb_build_object(
  'database', current_database(), 'role', current_user,
  'calendar_versions', (SELECT count(*) FROM public.workspace_calendar_versions),
  'calendar_exceptions', (SELECT count(*) FROM public.workspace_calendar_exceptions),
  'calendar_events', (SELECT count(*) FROM public.workspace_calendar_events),
  'calendar_versions_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(v)::text,
    '|' ORDER BY v.workspace_id::text), '')) FROM public.workspace_calendar_versions v),
  'calendar_exceptions_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.id::text), '')) FROM public.workspace_calendar_exceptions e),
  'calendar_events_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.operation_id::text), '')) FROM public.workspace_calendar_events e),
  'reschedule_changes', (SELECT count(*) FROM public.calendar_reschedule_changes),
  'reschedule_reversals', (SELECT count(*) FROM public.calendar_reschedule_reversals),
  'deletion_events', (SELECT count(*) FROM public.schedule_deletion_events),
  'movement_events', (SELECT count(*) FROM public.hierarchy_movement_events),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'activity_audits', (SELECT count(*) FROM public.activity_date_changes),
  'movement_ledger_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.operation_id::text), '')) FROM public.hierarchy_movement_events e),
  'deletion_ledger_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.operation_id::text), '')) FROM public.schedule_deletion_events e),
  'reschedule_ledger_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.batch_operation_id::text, e.activity_id::text), ''))
    FROM public.calendar_reschedule_changes e),
  'reversal_ledger_hash', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.reversal_date_operation_id::text), ''))
    FROM public.calendar_reschedule_reversals e)
)::text AS final_evidence;
ROLLBACK;
