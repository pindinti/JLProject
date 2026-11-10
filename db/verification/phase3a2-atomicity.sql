-- Run only on JLProject development after migration 0011.
-- This failure-injection test rolls back all synthetic changes and test objects.
BEGIN;

CREATE FUNCTION public.phase3a2_test_fail_clone_r00()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.import_batch_id IS NULL THEN
    RAISE EXCEPTION 'Synthetic R00 failure injection.' USING ERRCODE = 'PZ001';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER phase3a2_test_fail_clone_r00
  BEFORE INSERT ON public.initial_schedule_revisions
  FOR EACH ROW EXECUTE FUNCTION public.phase3a2_test_fail_clone_r00();

DO $$
DECLARE
  v_workspace uuid;
  v_actor uuid;
  v_source uuid;
  v_test_name text := 'Synthetic 3A2 rollback verification';
  v_caught boolean := false;
  v_products bigint;
  v_disciplines bigint;
  v_stages bigint;
  v_activities bigint;
  v_targets bigint;
  v_revisions bigint;
BEGIN
  SELECT id INTO STRICT v_workspace FROM public.workspaces WHERE name = 'JLProject';
  SELECT auth_user_id INTO STRICT v_actor FROM public.workspace_memberships
    WHERE workspace_id = v_workspace AND active = true AND role IN ('admin', 'editor')
    ORDER BY (role = 'admin') DESC LIMIT 1;
  SELECT id INTO STRICT v_source FROM public.products
    WHERE workspace_id = v_workspace AND name LIKE 'Synthetic 1C2 %' AND active = true;

  SELECT count(*) INTO v_products FROM public.products WHERE workspace_id = v_workspace;
  SELECT count(*) INTO v_disciplines FROM public.product_disciplines WHERE workspace_id = v_workspace;
  SELECT count(*) INTO v_stages FROM public.discipline_stages WHERE workspace_id = v_workspace;
  SELECT count(*) INTO v_activities FROM public.stage_activities WHERE workspace_id = v_workspace;
  SELECT count(*) INTO v_targets FROM public.business_targets WHERE workspace_id = v_workspace;
  SELECT count(*) INTO v_revisions FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace;

  BEGIN
    PERFORM public.clone_product(v_workspace, v_source, v_actor, v_test_name);
    RAISE EXCEPTION 'Failure injection did not run.' USING ERRCODE = 'PZ002';
  EXCEPTION WHEN SQLSTATE 'PZ001' THEN
    v_caught := true;
  END;

  IF NOT v_caught OR EXISTS (SELECT 1 FROM public.products
      WHERE workspace_id = v_workspace AND name = v_test_name) OR
     (SELECT count(*) FROM public.products WHERE workspace_id = v_workspace) <> v_products OR
     (SELECT count(*) FROM public.product_disciplines WHERE workspace_id = v_workspace) <> v_disciplines OR
     (SELECT count(*) FROM public.discipline_stages WHERE workspace_id = v_workspace) <> v_stages OR
     (SELECT count(*) FROM public.stage_activities WHERE workspace_id = v_workspace) <> v_activities OR
     (SELECT count(*) FROM public.business_targets WHERE workspace_id = v_workspace) <> v_targets OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE workspace_id = v_workspace) <> v_revisions THEN
    RAISE EXCEPTION 'Clone failure did not roll back every synthetic row.';
  END IF;
END;
$$;

DROP TRIGGER phase3a2_test_fail_clone_r00 ON public.initial_schedule_revisions;
DROP FUNCTION public.phase3a2_test_fail_clone_r00();

ROLLBACK;
