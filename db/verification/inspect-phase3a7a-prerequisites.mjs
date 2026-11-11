/* global console, process */
import { neon } from "@neondatabase/serverless";

if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required.");

const sql = neon(process.env.DATABASE_URL);
const constraints = await sql`
  SELECT conrelid::regclass::text AS table_name, conname,
    pg_get_constraintdef(oid) AS definition
  FROM pg_constraint
  WHERE conrelid IN (
    'public.discipline_stages'::regclass,
    'public.stage_activities'::regclass,
    'public.activity_date_changes'::regclass
  ) AND contype IN ('f', 'u', 'c')
  ORDER BY 1, 2
`;
const triggers = await sql`
  SELECT tgrelid::regclass::text AS table_name, tgname, tgenabled
  FROM pg_trigger
  WHERE tgrelid IN (
    'public.product_disciplines'::regclass,
    'public.discipline_stages'::regclass,
    'public.stage_activities'::regclass,
    'public.activity_date_changes'::regclass
  ) AND NOT tgisinternal
  ORDER BY 1, 2
`;
const columnPrivileges = await sql`
  SELECT grantee, table_name, privilege_type,
    string_agg(column_name, ',' ORDER BY column_name) AS columns
  FROM information_schema.column_privileges
  WHERE grantee IN ('jlproject_worker', 'jlproject_date_executor')
    AND table_schema = 'public'
    AND table_name IN (
      'product_disciplines', 'discipline_stages',
      'stage_activities', 'activity_date_changes'
    )
  GROUP BY grantee, table_name, privilege_type
  ORDER BY 1, 2, 3
`;
const state = await sql`
  SELECT
    to_regclass('public.hierarchy_movement_events')::text AS movement_table,
    to_regprocedure(
      'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'
    )::text AS movement_function,
    (SELECT count(*)::integer FROM public.products) AS products,
    (SELECT count(*)::integer FROM public.product_disciplines) AS disciplines,
    (SELECT count(*)::integer FROM public.discipline_stages) AS stages,
    (SELECT count(*)::integer FROM public.stage_activities) AS activities,
    (SELECT count(*)::integer FROM public.activity_date_changes) AS date_audits,
    (SELECT count(*)::integer FROM public.initial_schedule_revisions) AS r00_revisions,
    (SELECT count(*)::integer FROM public.business_targets) AS targets,
    (SELECT count(*)::integer FROM public.import_source_rows) AS import_rows
`;
const roleMemberships = await sql`
  SELECT member.rolname AS member, granted.rolname AS granted_role,
    membership.admin_option, membership.inherit_option, membership.set_option
  FROM pg_auth_members AS membership
  JOIN pg_roles AS member ON member.oid = membership.member
  JOIN pg_roles AS granted ON granted.oid = membership.roleid
  WHERE member.rolname IN ('neondb_owner', 'jlproject_worker')
    AND granted.rolname IN ('jlproject_worker', 'jlproject_date_executor')
  ORDER BY 1, 2
`;
const fingerprints = await sql`
  SELECT
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.id), ''))
      FROM public.products AS row) AS products,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.id), ''))
      FROM public.product_disciplines AS row) AS disciplines,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.id), ''))
      FROM public.discipline_stages AS row) AS stages,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.id), ''))
      FROM public.stage_activities AS row) AS activities,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.id), ''))
      FROM public.business_targets AS row) AS targets,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.id), ''))
      FROM public.initial_schedule_revisions AS row) AS r00,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n' ORDER BY row.operation_id), ''))
      FROM public.activity_date_changes AS row) AS date_audits,
    (SELECT md5(COALESCE(string_agg(to_jsonb(row)::text, E'\n'
      ORDER BY row.import_batch_id, row.source_sheet, row.source_row), ''))
      FROM public.import_source_rows AS row) AS import_rows
`;
const memberships = await sql`
  SELECT
    pg_has_role('neondb_owner', 'jlproject_worker', 'member') AS owner_is_worker_member,
    pg_has_role('neondb_owner', 'jlproject_worker', 'usage') AS owner_has_worker_usage,
    pg_has_role('neondb_owner', 'jlproject_worker', 'set') AS owner_can_set_worker,
    pg_has_role('neondb_owner', 'jlproject_date_executor', 'member') AS owner_is_executor_member,
    pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') AS owner_has_executor_usage,
    pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') AS owner_can_set_executor,
    pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') AS worker_is_executor_member,
    (SELECT count(*)::integer FROM public.workspace_memberships
      WHERE active = true AND role = 'admin') AS active_admins,
    (SELECT count(*)::integer FROM public.workspace_memberships
      WHERE active = true AND role = 'editor') AS active_editors,
    (SELECT count(*)::integer FROM public.workspace_memberships
      WHERE active = true AND role = 'viewer') AS active_viewers
`;
const privilegeSummary = await sql`
  SELECT jsonb_build_object(
    'workerMovementExecute', CASE WHEN to_regprocedure(
      'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'
    ) IS NULL THEN false ELSE has_function_privilege('jlproject_worker', to_regprocedure(
      'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'
    ), 'EXECUTE') END,
    'publicMovementExecute', CASE WHEN to_regprocedure(
      'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'
    ) IS NULL THEN false ELSE has_function_privilege('public', to_regprocedure(
      'public.move_schedule_item(uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,uuid,integer,jsonb,jsonb)'
    ), 'EXECUTE') END,
    'workerMovementTableSelect', CASE WHEN to_regclass('public.hierarchy_movement_events') IS NULL
      THEN false ELSE has_table_privilege('jlproject_worker', 'public.hierarchy_movement_events', 'SELECT') END,
    'workerDisciplineOrderUpdate', has_column_privilege('jlproject_worker', 'public.product_disciplines', 'display_order', 'UPDATE'),
    'workerStageOrderUpdate', has_column_privilege('jlproject_worker', 'public.discipline_stages', 'display_order', 'UPDATE'),
    'workerActivityOrderUpdate', has_column_privilege('jlproject_worker', 'public.stage_activities', 'display_order', 'UPDATE'),
    'workerActivityParentUpdate', has_column_privilege('jlproject_worker', 'public.stage_activities', 'discipline_id', 'UPDATE') OR
      has_column_privilege('jlproject_worker', 'public.stage_activities', 'stage_id', 'UPDATE'),
    'workerR00Update', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE'),
    'workerR00Delete', has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE')
  ) AS value
`;

console.log(JSON.stringify({ state: state[0], roleMemberships, fingerprints: fingerprints[0],
  memberships: memberships[0], security: privilegeSummary[0]?.["value"],
  constraints, triggers, columnPrivileges }, null, 2));
