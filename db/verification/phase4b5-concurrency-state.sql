-- Include as neondb_owner to capture a product's full state for in-session comparison.
-- Use only synthetic IDs. The comparison includes the history watermark and all audit values.
\set ON_ERROR_STOP on
SELECT jsonb_build_object(
  'activities', (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id) FROM public.stage_activities a WHERE a.product_id = p.id),
  'edges', (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.product_schedule_dependencies e WHERE e.product_id = p.id),
  'cursor', (SELECT to_jsonb(s) FROM public.product_schedule_state s WHERE s.product_id = p.id),
  'operations', (SELECT jsonb_agg(to_jsonb(o) ORDER BY o.schedule_version) FROM public.product_schedule_operations o WHERE o.product_id = p.id),
  'events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.event_id) FROM public.product_schedule_operation_events e WHERE e.product_id = p.id),
  'links', (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.schedule_version, l.source_ledger, l.source_operation_id)
    FROM public.product_schedule_operation_links l WHERE l.product_id = p.id),
  'source_events', (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.schedule_version, s.source_ledger, s.link_kind, s.source_event_id)
    FROM public.product_schedule_operation_source_events s WHERE s.workspace_id = p.workspace_id AND s.product_id = p.id),
  'date_ledger', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.operation_id)
    FROM public.activity_date_changes d WHERE d.product_id = p.id)
)::text AS fixture_state
FROM public.products p WHERE p.workspace_id = :'workspace'::uuid AND p.id = :'product'::uuid
\gset
