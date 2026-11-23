\set ON_ERROR_STOP on

BEGIN READ ONLY;
SET LOCAL search_path = pg_catalog, pg_temp;

DO $contract$
DECLARE
  v_edges regclass := 'public.product_schedule_dependencies'::regclass;
  v_baselines regclass := 'public.initial_schedule_revisions'::regclass;
BEGIN
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = v_edges AND contype = 'f'
        AND confdeltype = 'r' AND convalidated AND array_length(conkey, 1) = 3 AND confrelid = 'public.stage_activities'::regclass) <> 2
     OR (SELECT count(*) FROM pg_constraint WHERE conrelid = v_edges AND contype = 'f'
        AND confdeltype = 'r' AND convalidated AND array_length(conkey, 1) = 3 AND confrelid = 'public.discipline_stages'::regclass) <> 2
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = v_edges AND contype = 'f'
        AND confdeltype = 'r' AND convalidated AND array_length(conkey, 1) = 2 AND confrelid = 'public.products'::regclass)
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = v_edges AND contype = 'p'
        AND pg_get_constraintdef(oid) = 'PRIMARY KEY (id)')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = v_edges AND contype = 'c'
        AND conname = 'product_schedule_dependencies_endpoint_shape' AND convalidated) THEN
    RAISE EXCEPTION 'Dependency storage is missing its scoped endpoint or identity constraints.';
  END IF;

  IF (SELECT count(*) FROM pg_index WHERE indrelid = v_edges AND indisvalid AND indpred IS NOT NULL AND indisunique) <> 2
     OR (SELECT count(*) FROM pg_index WHERE indrelid = v_edges AND indisvalid AND indpred IS NOT NULL AND NOT indisunique) <> 2 THEN
    RAISE EXCEPTION 'Dependency storage is missing pair uniqueness or reverse lookup indexes.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_class AS relation,
       LATERAL aclexplode(COALESCE(relation.relacl, acldefault('r', relation.relowner))) AS acl
       WHERE relation.oid = v_edges AND acl.grantee = 0)
     OR EXISTS (SELECT 1 FROM unnest(ARRAY['jlproject_worker', 'jlproject_date_executor']) AS roles(role_name)
       WHERE has_table_privilege(role_name, v_edges, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
         OR has_any_column_privilege(role_name, v_edges, 'SELECT, INSERT, UPDATE, REFERENCES'))
     OR EXISTS (SELECT 1 FROM public.product_schedule_dependencies) THEN
    RAISE EXCEPTION 'The storage-only checkpoint must start empty with application access disabled.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = v_baselines AND NOT tgisinternal
       AND tgname = 'initial_schedule_revisions_immutable' AND tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = v_baselines AND contype = 'c'
       AND conname = 'initial_schedule_revisions_snapshot_check' AND convalidated
       AND position('[]' IN pg_get_constraintdef(oid)) > 0)
     OR has_table_privilege('jlproject_worker', v_baselines, 'UPDATE, DELETE') THEN
    RAISE EXCEPTION 'R00 protections changed during storage preparation.';
  END IF;
END;
$contract$;

COMMIT;
