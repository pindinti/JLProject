-- Run through a direct Worker connection to the verified disposable child.
-- The synthetic workspace and its active admin membership must already be committed.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('jlproject.test_calendar_setup_workspace', :'test_workspace', true),
  set_config('jlproject.test_calendar_setup_actor', :'test_actor', true);

DO $setup$
DECLARE
  v_workspace uuid := current_setting('jlproject.test_calendar_setup_workspace')::uuid;
  v_actor uuid := current_setting('jlproject.test_calendar_setup_actor')::uuid;
  v_result jsonb;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker'
    OR NOT EXISTS (SELECT 1 FROM public.workspaces
      WHERE id = v_workspace AND name = 'Synthetic Phase 4B.3b.1 workspace')
    OR NOT EXISTS (SELECT 1 FROM public.workspace_memberships
      WHERE workspace_id = v_workspace AND auth_user_id = v_actor AND active AND role = 'admin') THEN
    RAISE EXCEPTION 'Expected a direct Worker session and an active synthetic workspace admin.';
  END IF;

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(), 0,
    'create', NULL, 'company_shutdown', NULL, NULL, 'Synthetic prior closure', DATE '2026-11-02', DATE '2026-11-02');
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Expected the first synthetic calendar version.';
  END IF;

  v_result := public.change_workspace_calendar(v_workspace, v_actor, gen_random_uuid(), 1,
    'create', NULL, 'company_shutdown', NULL, NULL, 'Synthetic current closure', DATE '2026-11-10', DATE '2026-11-13');
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Expected the second synthetic calendar version.';
  END IF;
END;
$setup$;

COMMIT;
