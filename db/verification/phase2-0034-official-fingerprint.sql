\set ON_ERROR_STOP on

BEGIN READ ONLY;
SELECT current_database() AS database_name, current_user AS role_name,
  to_regprocedure('public.clone_product(uuid,uuid,uuid,text)') IS NOT NULL AS clone_exists,
  to_regprocedure('public.change_product_status(uuid,uuid,uuid,text,bigint,text)') IS NOT NULL AS status_function_exists,
  EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.products'::regclass
    AND attname = 'planning_classification' AND NOT attisdropped) AS classification_exists;
SELECT count(*) AS total_products,
  count(*) FILTER (WHERE active) AS active_products,
  count(*) FILTER (WHERE NOT active) AS archived_products,
  md5(COALESCE(string_agg(id::text || '|' || active::text || '|' || version::text || '|' ||
    name || '|' || COALESCE(description, ''), E'\n' ORDER BY id), '')) AS product_fingerprint
FROM public.products;
SELECT count(*) AS r00_count,
  md5(COALESCE(string_agg(id::text || '|' || snapshot::text, E'\n' ORDER BY id), '')) AS r00_fingerprint
FROM public.initial_schedule_revisions WHERE label = 'R00';
SELECT count(*) AS cursor_count,
  md5(COALESCE(string_agg(product_id::text || '|' || schedule_version::text || '|' ||
    history_watermark::text, E'\n' ORDER BY product_id), '')) AS cursor_fingerprint
FROM public.product_schedule_state;
SELECT count(*) AS operation_count, count(*) FILTER (WHERE operation_type = 'product_status_changed') AS status_operations
FROM public.product_schedule_operations;
SELECT 'product_disciplines' AS entity, count(*) AS rows,
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) AS fingerprint FROM public.product_disciplines t
UNION ALL SELECT 'discipline_stages', count(*),
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM public.discipline_stages t
UNION ALL SELECT 'stage_activities', count(*),
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM public.stage_activities t
UNION ALL SELECT 'business_targets', count(*),
  md5(COALESCE(string_agg(to_jsonb(t)::text, E'\n' ORDER BY t.id), '')) FROM public.business_targets t;
COMMIT;
