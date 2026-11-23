-- Commit synthetic rows only on the verified disposable child, as neondb_owner.
\set ON_ERROR_STOP on
SELECT 1 / (:'phase4b5_disposable_branch_verified' = 'true')::int AS disposable_child_verified;
\i db/verification/phase4b5-seed-auth-identities-owner.sql

BEGIN;
SELECT 1 / (current_database() = 'neondb' AND current_user = 'neondb_owner'
  AND to_regprocedure('public.clone_schedule_dependencies(uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb)') IS NOT NULL)::int;
SELECT gen_random_uuid() AS workspace,
  :'test_actor'::uuid AS actor
\gset
INSERT INTO public.workspaces (id, name) VALUES (:'workspace', 'Synthetic Phase 4B.5 concurrency workspace');
INSERT INTO public.workspace_memberships (workspace_id, auth_user_id, role, active)
VALUES (:'workspace', :'actor', 'admin', true);

CREATE TEMP TABLE concurrency_cases ON COMMIT DROP AS
SELECT scenario, gen_random_uuid() AS product, gen_random_uuid() AS early, gen_random_uuid() AS late
FROM (VALUES ('cycle'), ('duplicate'), ('date'), ('calendar')) AS scenarios(scenario);

INSERT INTO public.products (id, workspace_id, name, created_by, updated_by)
SELECT product, :'workspace'::uuid, 'Synthetic concurrency ' || scenario, :'actor'::uuid, :'actor'::uuid
FROM concurrency_cases;
INSERT INTO public.stage_activities (id, workspace_id, product_id, name, planned_start, planned_end,
  display_order, created_by, updated_by)
SELECT activity.id, :'workspace'::uuid, scenario.product, activity.name, activity.day, activity.day,
  activity.position, :'actor'::uuid, :'actor'::uuid
FROM concurrency_cases AS scenario
CROSS JOIN LATERAL (VALUES (scenario.early, 'Early', DATE '2026-11-09', 0),
  (scenario.late, 'Late', DATE '2026-11-11', 1)) AS activity(id, name, day, position);
SELECT :'workspace' AS workspace, :'actor' AS actor, * FROM concurrency_cases ORDER BY scenario;
COMMIT;
