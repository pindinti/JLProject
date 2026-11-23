-- Run in a fresh direct owner session on the verified disposable child.
\set ON_ERROR_STOP on
BEGIN READ ONLY;

SELECT 1 / (current_database() = 'neondb' AND session_user = 'neondb_owner' AND
  current_user = 'neondb_owner' AND
  (:'phase4b5_expect_owner_set' IN ('true', 'false')))::int AS expected_session;

WITH memberships AS (
  SELECT grantor.rolname AS grantor, m.admin_option, m.inherit_option, m.set_option
  FROM pg_catalog.pg_auth_members m
  JOIN pg_catalog.pg_roles grantor ON grantor.oid = m.grantor
  WHERE m.roleid = 'jlproject_date_executor'::regrole AND m.member = 'neondb_owner'::regrole
)
SELECT 1 / (
  count(*) = (CASE WHEN :'phase4b5_expect_owner_set'::boolean THEN 2 ELSE 1 END)
  AND count(*) FILTER (WHERE grantor = 'cloud_admin' AND admin_option
    AND NOT inherit_option AND NOT set_option) = 1
  AND count(*) FILTER (WHERE grantor = 'neondb_owner' AND NOT admin_option
    AND NOT inherit_option AND set_option) = (:'phase4b5_expect_owner_set'::boolean)::int
  AND pg_has_role('neondb_owner', 'jlproject_date_executor', 'SET') = :'phase4b5_expect_owner_set'::boolean
  AND NOT pg_has_role('jlproject_worker', 'jlproject_date_executor', 'MEMBER')
  AND NOT has_function_privilege('jlproject_worker',
    'public.confirm_schedule_dependencies(uuid,uuid,uuid,uuid,bigint,bigint,text,text,jsonb,jsonb)', 'EXECUTE')
)::int AS expected_grantors_and_effective_permissions
FROM memberships;
ROLLBACK;
