-- REL-03P protected-ledger baseline/residue check.
-- Run before and after the Worker test, on the rehearsal branch only, with an
-- independently authorized SELECT role. Never switch or grant roles here.
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '30s';
SELECT 1 / CASE WHEN current_database() = 'neondb' AND
  has_table_privilege(current_user, 'public.hierarchy_movement_events', 'SELECT')
  THEN 1 ELSE 0 END AS authorized_ledger_reader;
SELECT count(*) AS movement_event_count,
  md5(COALESCE(string_agg(to_jsonb(event)::text,
    '|' ORDER BY operation_id::text), '')) AS movement_ledger_fingerprint
FROM public.hierarchy_movement_events AS event;
ROLLBACK;
