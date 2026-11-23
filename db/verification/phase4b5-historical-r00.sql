\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '1min';
SELECT set_config('jlproject.phase4b5.excluded_clone_workspace',
  NULLIF(:'excluded_clone_workspace', 'none')::uuid::text, true);

DO $historical_r00$
DECLARE
  v_excluded uuid := NULLIF(current_setting('jlproject.phase4b5.excluded_clone_workspace', true), '')::uuid;
  v_count bigint;
  v_fingerprint text;
BEGIN
  SELECT count(*), md5(COALESCE(string_agg(to_jsonb(r)::text, E'\n' ORDER BY r.id), ''))
    INTO v_count, v_fingerprint
  FROM public.initial_schedule_revisions AS r
  WHERE r.workspace_id IS DISTINCT FROM v_excluded;
  IF v_count <> 6 OR v_fingerprint IS DISTINCT FROM '9b6daa6196b11b3bee428a1d96fcd1c1' THEN
    RAISE EXCEPTION 'Historical R00 verification failed (count %, fingerprint %).', v_count, v_fingerprint;
  END IF;
  RAISE NOTICE 'Historical R00 verified: % rows, fingerprint %.', v_count, v_fingerprint;
END;
$historical_r00$;
ROLLBACK;
