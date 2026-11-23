\set ON_ERROR_STOP on
BEGIN READ ONLY;
\conninfo
SELECT 'handoff|' || :'test_workspace' || '|' || :'fixed_successor_stage' || '|' ||
  :'violation_successor_stage' || '|' || :'missing_target_name' || '|' ||
  current_setting('transaction_read_only');
ROLLBACK;
\if :probe_fail
SELECT 1 / 0;
\endif
