-- Include inside a read-only owner transaction. Normalize only the intended collision writes.
SET LOCAL statement_timeout = '1min';
SET LOCAL timezone = 'UTC';
SELECT set_config('jlproject.phase4b3c3_collision_check', jsonb_build_object(
  'workspace', :'test_workspace', 'actor', :'test_actor', 'product', :'test_empty_product',
  'activity', :'test_collision_activity', 'operation', :'test_late_colliding_operation')::text, true) AS scope \gset

DO $scope$
DECLARE
  v_scope jsonb := current_setting('jlproject.phase4b3c3_collision_check')::jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner'
     OR current_setting('transaction_read_only') <> 'on'
     OR NOT EXISTS (SELECT 1 FROM public.workspaces WHERE id = (v_scope->>'workspace')::uuid
       AND name = 'Synthetic Phase 4B.3c.3 schedule deletion workspace')
     OR has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'SELECT')
     OR has_table_privilege('jlproject_worker', 'public.product_schedule_dependencies', 'SELECT') THEN
    RAISE EXCEPTION '0043 collision observer requires the synthetic workspace, read-only owner session and private storage.';
  END IF;
END;
$scope$;

WITH ids AS (
  SELECT :'test_workspace'::uuid AS workspace, :'test_empty_product'::uuid AS product,
    :'test_collision_activity'::uuid AS activity, :'test_late_colliding_operation'::uuid AS operation
), records(kind, payload) AS (
  SELECT 'product', to_jsonb(p) FROM public.products p, ids i WHERE p.workspace_id = i.workspace
  UNION ALL SELECT 'discipline', to_jsonb(d) FROM public.product_disciplines d, ids i WHERE d.workspace_id = i.workspace
  UNION ALL SELECT 'stage', to_jsonb(s) FROM public.discipline_stages s, ids i WHERE s.workspace_id = i.workspace
  UNION ALL SELECT 'activity', CASE WHEN a.product_id = i.product AND a.id = i.activity
      THEN to_jsonb(a) - ARRAY['deleted_at','deletion_operation_id','version','updated_by','updated_at']
      ELSE to_jsonb(a) END FROM public.stage_activities a, ids i WHERE a.workspace_id = i.workspace
  UNION ALL SELECT 'graph', to_jsonb(e) FROM public.product_schedule_dependencies e, ids i WHERE e.workspace_id = i.workspace
  UNION ALL SELECT 'cursor', CASE WHEN s.product_id = i.product
      THEN to_jsonb(s) - ARRAY['schedule_version','history_watermark','updated_at']
      ELSE to_jsonb(s) END FROM public.product_schedule_state s, ids i WHERE s.workspace_id = i.workspace
  UNION ALL SELECT 'deletion', to_jsonb(d) FROM public.schedule_deletion_events d, ids i
    WHERE d.workspace_id = i.workspace AND (d.product_id, d.operation_id) <> (i.product, i.operation)
  UNION ALL SELECT 'operation', to_jsonb(o) FROM public.product_schedule_operations o, ids i
    WHERE o.workspace_id = i.workspace AND (o.product_id, o.operation_id) <> (i.product, i.operation)
  UNION ALL SELECT 'event', to_jsonb(e) FROM public.product_schedule_operation_events e, ids i
    WHERE e.workspace_id = i.workspace AND (e.product_id, e.operation_id) <> (i.product, i.operation)
  UNION ALL SELECT 'link', to_jsonb(l) FROM public.product_schedule_operation_links l, ids i
    WHERE l.workspace_id = i.workspace AND (l.product_id, l.operation_id) <> (i.product, i.operation)
  UNION ALL SELECT 'source', to_jsonb(e) FROM public.product_schedule_operation_source_events e, ids i
    WHERE e.workspace_id = i.workspace AND (e.product_id, e.operation_id) <> (i.product, i.operation)
  UNION ALL SELECT 'activity dates', to_jsonb(a) FROM public.activity_date_changes a, ids i WHERE a.workspace_id = i.workspace
  UNION ALL SELECT 'stage dates', to_jsonb(s) FROM public.stage_date_changes s, ids i WHERE s.workspace_id = i.workspace
)
SELECT md5(jsonb_agg(jsonb_build_array(kind, payload) ORDER BY kind, payload::text COLLATE "C")::text)
  AS collision_state_fingerprint FROM records \gset
