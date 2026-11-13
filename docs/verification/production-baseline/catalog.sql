-- Documentation-only inspection query. Not executed by the repository review.
-- Run only with an approved read-only inspection role after independently
-- verifying the Production project/branch in the provider console.
\set ON_ERROR_STOP on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = '10s';
SET LOCAL lock_timeout = '1s';
SET LOCAL idle_in_transaction_session_timeout = '30s';

-- SQL identity and server version. These values do not identify a Neon branch.
SELECT current_database() AS database_name,
       current_user AS connected_role,
       current_setting('server_version') AS server_version,
       current_setting('server_version_num') AS server_version_num,
       current_schema() AS current_schema,
       current_setting('search_path') AS search_path,
       current_setting('transaction_read_only') AS transaction_read_only,
       pg_is_in_recovery() AS is_read_replica;

-- Application schemas and owners.
SELECT n.nspname AS schema_name, pg_get_userbyid(n.nspowner) AS schema_owner
FROM pg_namespace AS n
WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
ORDER BY n.nspname;

-- Tables, views, sequences and owners. Size is catalog/statistical evidence, not an exact row count.
SELECT n.nspname AS schema_name, c.relname AS relation_name, c.relkind,
       pg_get_userbyid(c.relowner) AS relation_owner,
       CASE WHEN c.relkind IN ('r', 'p', 'm') THEN pg_total_relation_size(c.oid) END AS total_bytes
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
ORDER BY n.nspname, c.relname;

-- Column shape and default presence for relations corresponding to migrations 0001-0027.
-- Default expressions are intentionally not returned.
SELECT c.oid::regclass AS relation_name, a.attnum AS ordinal,
       a.attname AS column_name, format_type(a.atttypid, a.atttypmod) AS data_type,
       a.attnotnull AS not_null, (d.adbin IS NOT NULL) AS has_default
FROM pg_attribute AS a
JOIN pg_class AS c ON c.oid = a.attrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef AS d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p')
  AND c.relname = ANY (ARRAY[
    'workspaces', 'workspace_memberships', 'products', 'product_disciplines',
    'stage_definitions', 'discipline_stages', 'stage_activities', 'business_targets',
    'import_batches', 'import_source_rows', 'initial_schedule_revisions',
    'activity_date_changes', 'business_target_date_changes', 'workspace_calendar_versions',
    'workspace_calendar_exceptions', 'workspace_calendar_events', 'calendar_reschedule_changes',
    'calendar_reschedule_reversals', 'schedule_deletion_events', 'hierarchy_movement_events'
  ])
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY relation_name, a.attnum;

-- Constraints (including whether PostgreSQL validated them) and definitions.
SELECT conrelid::regclass AS relation_name, conname AS constraint_name,
       contype AS constraint_type, convalidated AS validated,
       condeferrable AS deferrable, condeferred AS initially_deferred,
       pg_get_constraintdef(pg_constraint.oid, true) AS definition
FROM pg_constraint
JOIN pg_namespace AS constraint_schema ON constraint_schema.oid = connamespace
WHERE constraint_schema.nspname = 'public'
ORDER BY relation_name, conname;

-- Index validity and definitions; this is metadata inspection, not index verification by scan.
SELECT i.indrelid::regclass AS relation_name, ci.relname AS index_name,
       i.indisunique AS is_unique, i.indisvalid AS is_valid,
       i.indisready AS is_ready, pg_get_indexdef(i.indexrelid) AS definition
FROM pg_index AS i
JOIN pg_class AS ci ON ci.oid = i.indexrelid
JOIN pg_namespace AS n ON n.oid = ci.relnamespace
WHERE n.nspname = 'public'
  AND i.indrelid IN (
    SELECT c.oid FROM pg_class AS c
    JOIN pg_namespace AS rn ON rn.oid = c.relnamespace
    WHERE rn.nspname = 'public' AND c.relkind IN ('r', 'p')
  )
ORDER BY relation_name, index_name;

-- Function signatures, owners, security mode, configured settings, and effective Worker EXECUTE.
SELECT n.nspname AS schema_name, p.proname AS function_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       pg_get_userbyid(p.proowner) AS owner, p.prosecdef AS security_definer,
       p.proconfig AS function_settings,
       has_function_privilege(to_regrole('jlproject_worker'), p.oid, 'EXECUTE') AS worker_execute
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
ORDER BY p.proname, arguments;

-- Non-internal trigger attachment and enabled state.
SELECT c.oid::regclass AS relation_name, t.tgname AS trigger_name,
       t.tgenabled AS enabled_state, pg_get_triggerdef(t.oid, true) AS definition
FROM pg_trigger AS t
JOIN pg_class AS c ON c.oid = t.tgrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname IN ('public', 'neon_auth')
ORDER BY relation_name, trigger_name;

-- Role attributes and membership edges; no password/authentication fields are selected.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole,
       rolinherit, rolbypassrls, rolreplication
FROM pg_roles
WHERE rolname IN ('neondb_owner', 'jlproject_worker',
                  'jlproject_date_executor', 'jlproject_calendar_executor')
ORDER BY rolname;

SELECT granted.rolname AS granted_role, member.rolname AS member_role,
       m.admin_option,
       to_jsonb(m) ->> 'inherit_option' AS inherit_option,
       to_jsonb(m) ->> 'set_option' AS set_option
FROM pg_auth_members AS m
JOIN pg_roles AS granted ON granted.oid = m.roleid
JOIN pg_roles AS member ON member.oid = m.member
ORDER BY granted_role, member_role;

-- Explicit ACLs for roles reachable from the application/owner role set, plus
-- PUBLIC. Review these together with the complete membership graph above.
WITH RECURSIVE role_scope(role_oid) AS (
  SELECT oid FROM pg_roles
  WHERE rolname IN ('neondb_owner', 'jlproject_worker',
                    'jlproject_date_executor', 'jlproject_calendar_executor')
  UNION
  SELECT membership.roleid
  FROM pg_auth_members AS membership
  JOIN role_scope AS member_role ON member_role.role_oid = membership.member
), acl_rows AS (
  SELECT n.nspname AS schema_name, c.relname AS object_name,
         CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END AS grantee,
         acl.grantee AS grantee_oid, acl.privilege_type, acl.is_grantable
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl,
    acldefault(CASE WHEN c.relkind = 'S' THEN 'S'::"char" ELSE 'r'::"char" END,
      c.relowner))) AS acl
  LEFT JOIN pg_roles AS grantee ON grantee.oid = acl.grantee
  WHERE n.nspname IN ('public', 'neon_auth')
    AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
)
SELECT schema_name, object_name, grantee, privilege_type, is_grantable
FROM acl_rows
WHERE grantee = 'PUBLIC'
   OR grantee_oid IN (SELECT role_oid FROM role_scope)
ORDER BY schema_name, object_name, grantee, privilege_type;

WITH RECURSIVE role_scope(role_oid) AS (
  SELECT oid FROM pg_roles
  WHERE rolname IN ('neondb_owner', 'jlproject_worker',
                    'jlproject_date_executor', 'jlproject_calendar_executor')
  UNION
  SELECT membership.roleid FROM pg_auth_members AS membership
  JOIN role_scope AS member_role ON member_role.role_oid = membership.member
)
SELECT n.nspname AS schema_name, c.relname AS object_name, a.attname AS column_name,
       CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END AS grantee,
       acl.grantee AS grantee_oid, acl.privilege_type, acl.is_grantable
FROM pg_attribute AS a
JOIN pg_class AS c ON c.oid = a.attrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(a.attacl) AS acl
LEFT JOIN pg_roles AS grantee ON grantee.oid = acl.grantee
WHERE n.nspname IN ('public', 'neon_auth') AND a.attnum > 0
  AND NOT a.attisdropped
  AND (acl.grantee = 0 OR acl.grantee IN (SELECT role_oid FROM role_scope))
ORDER BY schema_name, object_name, column_name, grantee, acl.privilege_type;

WITH RECURSIVE role_scope(role_oid) AS (
  SELECT oid FROM pg_roles
  WHERE rolname IN ('neondb_owner', 'jlproject_worker',
                    'jlproject_date_executor', 'jlproject_calendar_executor')
  UNION
  SELECT membership.roleid FROM pg_auth_members AS membership
  JOIN role_scope AS member_role ON member_role.role_oid = membership.member
)
SELECT n.nspname AS schema_name, p.proname AS routine_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END AS grantee,
       acl.grantee AS grantee_oid, acl.privilege_type, acl.is_grantable
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
LEFT JOIN pg_roles AS grantee ON grantee.oid = acl.grantee
WHERE n.nspname IN ('public', 'neon_auth')
  AND (acl.grantee = 0 OR acl.grantee IN (SELECT role_oid FROM role_scope))
ORDER BY schema_name, routine_name, arguments, grantee, acl.privilege_type;

WITH RECURSIVE role_scope(role_oid) AS (
  SELECT oid FROM pg_roles
  WHERE rolname IN ('neondb_owner', 'jlproject_worker',
                    'jlproject_date_executor', 'jlproject_calendar_executor')
  UNION
  SELECT membership.roleid FROM pg_auth_members AS membership
  JOIN role_scope AS member_role ON member_role.role_oid = membership.member
)
SELECT n.nspname AS schema_name,
       CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END AS grantee,
       acl.grantee AS grantee_oid, acl.privilege_type, acl.is_grantable
FROM pg_namespace AS n
CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) AS acl
LEFT JOIN pg_roles AS grantee ON grantee.oid = acl.grantee
WHERE n.nspname IN ('public', 'neon_auth')
  AND (acl.grantee = 0 OR acl.grantee IN (SELECT role_oid FROM role_scope))
ORDER BY schema_name, grantee, acl.privilege_type;

-- Candidate migration trackers. Presence is not evidence of completed migrations.
SELECT n.nspname AS schema_name, c.relname AS relation_name, c.relkind,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm')
  AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
  AND c.relname ~* '(migration|schema.?version|flyway|liquibase|prisma|drizzle)'
ORDER BY n.nspname, c.relname;

-- Migration 0025-0027 database-name guard. This does not identify a Neon project/branch.
SELECT current_database() AS database_name,
       current_database() = 'neondb' AS matches_0025_0027_database_name_guard,
       current_setting('server_version_num')::integer >= 160000
         AS supports_migration_0025_0027_role_options,
       current_user AS connected_role,
       to_regrole('neondb_owner') IS NOT NULL AS neondb_owner_present,
       to_regrole('jlproject_worker') IS NOT NULL AS worker_role_present,
       to_regrole('jlproject_date_executor') IS NOT NULL AS date_executor_present,
       CASE WHEN to_regrole('jlproject_worker') IS NOT NULL
                  AND to_regrole('jlproject_date_executor') IS NOT NULL
            THEN pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member')
       END AS worker_is_date_executor_member,
       CASE WHEN current_setting('server_version_num')::integer >= 160000
                  AND to_regrole('neondb_owner') IS NOT NULL
                  AND to_regrole('jlproject_date_executor') IS NOT NULL
            THEN pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage')
       END AS owner_has_date_executor_usage,
       CASE WHEN current_setting('server_version_num')::integer >= 160000
                  AND to_regrole('neondb_owner') IS NOT NULL
                  AND to_regrole('jlproject_date_executor') IS NOT NULL
            THEN pg_has_role('neondb_owner', 'jlproject_date_executor', 'set')
       END AS owner_can_set_date_executor,
       CASE WHEN to_regrole('jlproject_date_executor') IS NOT NULL
            THEN has_schema_privilege('jlproject_date_executor', 'public', 'CREATE')
       END AS date_executor_has_public_create;

-- Migration 0025-0027 structural preconditions. Missing rows mean absent objects, not proof of history.
SELECT expected.object_name, expected.object_kind,
       CASE expected.object_kind
         WHEN 'relation' THEN to_regclass(expected.object_name)::text
         WHEN 'function' THEN to_regprocedure(expected.object_name)::text
       END AS resolved_object
FROM (VALUES
  ('public.stage_activities', 'relation'),
  ('public.activity_date_changes', 'relation'),
  ('public.initial_schedule_revisions', 'relation'),
  ('public.stage_activities_root_order_idx', 'relation'),
  ('public.hierarchy_movement_events', 'relation'),
  ('public.change_activity_planning(uuid,uuid,uuid,uuid,uuid,uuid,uuid,text,date,date,integer,bigint,text,bigint)', 'function'),
  ('public.create_activity_with_working_plan(uuid,uuid,uuid,uuid,uuid,text,text,date,date,integer,text,integer,bigint)', 'function'),
  ('public.apply_calendar_reschedule(uuid,uuid,uuid,uuid,bigint,text,jsonb)', 'function'),
  ('public.reverse_calendar_reschedule(uuid,uuid,uuid,uuid,uuid,text)', 'function'),
  ('public.preview_schedule_deletion(uuid,uuid,uuid,text,uuid)', 'function'),
  ('public.delete_schedule_subtree(uuid,uuid,uuid,uuid,text,uuid,text,text)', 'function'),
  ('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'function'),
  ('public.clone_product(uuid,uuid,uuid,text)', 'function'),
  ('public.clone_root_activity(uuid,uuid,uuid,uuid,uuid)', 'function'),
  ('public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)', 'function')
) AS expected(object_name, object_kind)
ORDER BY expected.object_kind, expected.object_name;

-- Relevant parent-FK/column state for 0025 and 0026; absent relations return no rows.
SELECT c.relname AS relation_name, a.attname AS column_name, a.attnotnull AS not_null
FROM pg_attribute AS a
JOIN pg_class AS c ON c.oid = a.attrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND (c.relname, a.attname) IN (
    ('stage_activities', 'discipline_id'), ('stage_activities', 'stage_id'),
    ('activity_date_changes', 'discipline_id'), ('activity_date_changes', 'stage_id')
  ) AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY relation_name, column_name;

SELECT conrelid::regclass AS relation_name, conname, contype,
       convalidated, condeferrable, condeferred
FROM pg_constraint
WHERE conrelid IN (to_regclass('public.stage_activities'),
                   to_regclass('public.activity_date_changes'))
  AND conname IN ('stage_activities_parent_fk',
                  'stage_activities_parent_pair_check',
                  'stage_activities_product_scope_fk',
                  'activity_date_changes_activity_fk',
                  'activity_date_changes_parent_pair_check',
                  'activity_date_changes_product_scope_fk')
ORDER BY relation_name, conname;

-- Migration 0027 checks that this exact source anchor occurs once and that movement
-- events have not already been added to the current product-history function.
WITH target AS (
  SELECT to_regprocedure(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'
  ) AS function_oid
), source AS (
  SELECT CASE WHEN function_oid IS NOT NULL THEN pg_get_functiondef(function_oid) END AS definition
  FROM target
), measured AS (
  SELECT definition,
         '  ), eligible AS MATERIALIZED (' AS anchor
  FROM source
)
SELECT definition IS NOT NULL AS history_function_present,
       CASE WHEN definition IS NOT NULL THEN
         (length(definition) - length(replace(definition, anchor, ''))) / length(anchor)
       END AS checked_anchor_occurrences,
       CASE WHEN definition IS NOT NULL THEN
         position('public.hierarchy_movement_events' IN definition) > 0
       END AS function_already_mentions_movement_events
FROM measured;

ROLLBACK;
