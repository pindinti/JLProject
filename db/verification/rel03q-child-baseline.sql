-- REL-03Q: read-only baseline for the disposable child after migration 0026.
-- Run as neondb_owner only on a branch whose parent ID was verified externally.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT jsonb_build_object(
  'database', current_database(), 'role', current_user,
  'products', (SELECT count(*) FROM public.products),
  'disciplines', (SELECT count(*) FROM public.product_disciplines),
  'stages', (SELECT count(*) FROM public.discipline_stages),
  'activities', (SELECT count(*) FROM public.stage_activities),
  'date_audits', (SELECT count(*) FROM public.activity_date_changes),
  'r00', (SELECT count(*) FROM public.initial_schedule_revisions),
  'movement_events', (SELECT count(*) FROM public.hierarchy_movement_events),
  'movement_fingerprint', (SELECT md5(COALESCE(string_agg(to_jsonb(e)::text,
    '|' ORDER BY e.operation_id::text), '')) FROM public.hierarchy_movement_events AS e),
  'date_fingerprint', (SELECT md5(COALESCE(string_agg(jsonb_build_object(
    'id', a.id, 'planned_start', a.planned_start, 'planned_end', a.planned_end)::text,
    '|' ORDER BY a.id::text), '')) FROM public.stage_activities AS a),
  'hierarchy_fingerprint', (SELECT md5(COALESCE(string_agg(row_data,
    '|' ORDER BY kind, id), '')) FROM (
      SELECT 'd' AS kind, d.id::text AS id, to_jsonb(d)::text AS row_data
        FROM public.product_disciplines AS d
      UNION ALL SELECT 's', s.id::text, to_jsonb(s)::text FROM public.discipline_stages AS s
      UNION ALL SELECT 'a', a.id::text, to_jsonb(a)::text FROM public.stage_activities AS a
    ) AS rows),
  'r00_fingerprint', (SELECT md5(COALESCE(string_agg(r.id::text || '|' ||
    r.snapshot::text, E'\n' ORDER BY r.id), ''))
    FROM public.initial_schedule_revisions AS r),
  'target_fingerprint', (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text,
    '|' ORDER BY t.id::text), '')) FROM public.business_targets AS t),
  'source_rows', (SELECT count(*) FROM public.import_source_rows),
  'fixture_rows', (SELECT count(*) FROM public.products WHERE id =
    '7c000000-0000-4000-8000-000000000001'::uuid OR name LIKE 'REL03Q synthetic %'),
  'owner_can_select_ledger', has_table_privilege(current_user,
    'public.hierarchy_movement_events', 'SELECT'),
  'unreviewed_write_triggers', (SELECT count(*) FROM pg_trigger AS tr
    JOIN pg_class AS rel ON rel.oid = tr.tgrelid
    JOIN pg_namespace AS ns ON ns.oid = rel.relnamespace
    WHERE ns.nspname = 'public' AND NOT tr.tgisinternal
      AND tr.tgenabled IN ('O', 'A')
      AND rel.relname IN ('products', 'product_disciplines',
        'stage_definitions', 'discipline_stages', 'stage_activities',
        'hierarchy_movement_events')
      AND tr.tgname NOT IN ('product_disciplines_deletion_guard',
        'discipline_stages_deletion_guard', 'stage_activities_deletion_guard',
        'stage_activities_dates_immutable', 'hierarchy_movement_events_immutable')),
  'movement_function_installed',
    to_regprocedure('public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)') IS NOT NULL,
  'owner_can_update_ledger', has_table_privilege(current_user,
    'public.hierarchy_movement_events', 'UPDATE')
) AS baseline;
ROLLBACK;
