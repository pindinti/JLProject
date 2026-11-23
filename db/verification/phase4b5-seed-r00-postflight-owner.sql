-- Include after an owner seed session's committed setup and audited dependency additions.
\set ON_ERROR_STOP on
SELECT set_config('jlproject.phase4b5_seed_workspace', :'test_workspace', false);

DO $postflight$
DECLARE
  v_before record;
  v_count bigint;
  v_fingerprint text;
  v_workspace uuid := current_setting('jlproject.phase4b5_seed_workspace')::uuid;
BEGIN
  SELECT row_count, fingerprint INTO STRICT v_before FROM pg_temp.phase4b5_seed_r00_baseline;
  SELECT count(*)::bigint,
    md5(COALESCE(string_agg(to_jsonb(revision)::text, E'\n' ORDER BY revision.id), ''))
    INTO v_count, v_fingerprint
  FROM public.initial_schedule_revisions AS revision;
  IF v_before.row_count <> 6 OR v_count <> v_before.row_count OR v_fingerprint <> v_before.fingerprint
     OR EXISTS (SELECT 1 FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace) THEN
    RAISE EXCEPTION 'Fixture setup changed historical R00 rows or created a fixture R00 baseline.';
  END IF;
END;
$postflight$;
