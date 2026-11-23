-- Include from an open READ COMMITTED transaction as jlproject_date_executor.
-- The caller supplies a captured snapshot, a fresh operation/edge ID and two root activity IDs.
\set ON_ERROR_STOP on
SELECT public.confirm_schedule_dependencies(
  :'workspace'::uuid, :'product'::uuid, :'actor'::uuid, :'operation'::uuid,
  :'schedule_version'::bigint, :'calendar_version'::bigint, :'fingerprint',
  'Synthetic concurrent graph confirmation', '[]'::jsonb,
  jsonb_build_object('kind', 'add', 'dependency', jsonb_build_object('id', :'edge'::uuid,
    'predecessor', jsonb_build_object('productId', :'product'::uuid, 'kind', 'activity', 'id', :'from_id'::uuid),
    'successor', jsonb_build_object('productId', :'product'::uuid, 'kind', 'activity', 'id', :'to_id'::uuid)))
)->>'status' AS confirmation_status
\gset
\echo Confirmation status: :confirmation_status
SELECT 1 / (:'confirmation_status' = :'expected_status')::integer AS expected_confirmation;
