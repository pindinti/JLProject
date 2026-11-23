-- Include at the start of an owner seed session on a separately verified disposable child.
-- The embedded Neon CLI psql mishandles \if in -f files and ignores \quit's status.
\set ON_ERROR_STOP on

SELECT set_config('jlproject.phase4b5.disposable_child_verified',
  :'phase4b5_disposable_child_verified', false);

DO $preflight$
BEGIN
  IF current_setting('jlproject.phase4b5.disposable_child_verified') <> 'true' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'A verified disposable Development child is required before running this owner seed.';
  END IF;

  IF current_database() <> 'neondb' OR current_user <> 'neondb_owner'
    OR to_regclass('public.product_schedule_dependencies') IS NULL
    OR to_regclass('public.initial_schedule_revisions') IS NULL
    OR (SELECT count(*) FROM public.initial_schedule_revisions) <> 6
    OR pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') THEN
    RAISE EXCEPTION 'Expected the verified child owner, complete dependency storage, six historical R00 rows, and no temporary executor membership.';
  END IF;
END;
$preflight$;

RESET jlproject.phase4b5.disposable_child_verified;

CREATE TEMP TABLE phase4b5_seed_r00_baseline ON COMMIT PRESERVE ROWS AS
SELECT count(*)::bigint AS row_count,
  md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), '')) AS fingerprint
FROM public.initial_schedule_revisions AS revision;
