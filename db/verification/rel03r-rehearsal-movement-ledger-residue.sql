-- REL-03R independent read-only ledger residue check; run as neondb_owner.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
DO $$
DECLARE
  v_count bigint;
  v_fingerprint text;
BEGIN
  IF current_database() IS DISTINCT FROM 'neondb' OR
     current_user IS DISTINCT FROM 'neondb_owner' OR
     NOT has_table_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT') THEN
    RAISE EXCEPTION 'Owner read-only ledger verification role or database differs.';
  END IF;
  SELECT count(*), md5(COALESCE(string_agg(operation_id::text,
    '|' ORDER BY operation_id::text), '')) INTO v_count, v_fingerprint
    FROM public.hierarchy_movement_events;
  IF v_count IS DISTINCT FROM 0 OR
     v_fingerprint IS DISTINCT FROM 'd41d8cd98f00b204e9800998ecf8427e' OR
     EXISTS (SELECT 1 FROM public.hierarchy_movement_events
       WHERE product_id = '7c000000-0000-4000-8000-000000000001'::uuid) THEN
    RAISE EXCEPTION 'Movement ledger residue or baseline fingerprint differs.';
  END IF;
  RAISE NOTICE 'REL-03R owner ledger residue: 0 events, empty fingerprint, no fixture events.';
END;
$$;
ROLLBACK;
