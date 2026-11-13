-- REL-05G: 0010-through-0027 original-data invariants, read only.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '1s';
SELECT 1 / CASE WHEN current_database() = 'neondb' AND current_user = 'neondb_owner'
  AND current_setting('transaction_read_only') = 'on'
  AND (SELECT count(*) FROM public.workspaces) = 1
  AND (SELECT count(*) FROM public.workspace_memberships) = 4
  AND (SELECT count(*) FROM public.workspace_memberships WHERE active AND role = 'admin') = 1
  AND (SELECT count(*) FROM public.workspace_memberships WHERE active AND role = 'editor') = 3
  AND (SELECT count(*) FROM public.workspace_memberships WHERE NOT active OR role = 'viewer') = 0
  AND (SELECT count(*) FROM public.products) = 6
  AND (SELECT count(*) FROM public.products WHERE active) = 6
  AND (SELECT count(*) FROM public.business_targets) = 19
  AND (SELECT count(*) FROM public.business_targets WHERE deleted_at IS NOT NULL) = 4
  AND (SELECT count(*) FROM public.stage_activities) = 99
  AND (SELECT count(*) FROM public.stage_activities WHERE
    planned_start IS NULL OR planned_end IS NULL OR planned_start > planned_end) = 0
  AND (SELECT count(*) FROM public.stage_activities WHERE
    discipline_id IS NULL OR stage_id IS NULL) = 0
  AND NOT EXISTS (SELECT 1 FROM public.product_disciplines d
    LEFT JOIN public.products p ON p.workspace_id = d.workspace_id AND p.id = d.product_id
    WHERE p.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.discipline_stages s
    LEFT JOIN public.product_disciplines d ON d.workspace_id = s.workspace_id
      AND d.product_id = s.product_id AND d.id = s.discipline_id WHERE d.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.stage_activities a
    LEFT JOIN public.discipline_stages s ON s.workspace_id = a.workspace_id
      AND s.product_id = a.product_id AND s.discipline_id = a.discipline_id
      AND s.id = a.stage_id WHERE s.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.business_targets t
    LEFT JOIN public.products p ON p.workspace_id = t.workspace_id AND p.id = t.product_id
    WHERE p.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.import_batches b
    LEFT JOIN public.products p ON p.workspace_id = b.workspace_id AND p.id = b.product_id
    WHERE p.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.import_source_rows r
    LEFT JOIN public.import_batches b ON b.id = r.import_batch_id WHERE b.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM public.initial_schedule_revisions r
    LEFT JOIN public.products p ON p.workspace_id = r.workspace_id AND p.id = r.product_id
    WHERE p.id IS NULL)
  AND NOT EXISTS (SELECT 1 FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = rel.relnamespace
    WHERE ns.nspname = 'public' AND NOT con.convalidated)
  THEN 1 ELSE 0 END AS original_data_gate;
ROLLBACK;
