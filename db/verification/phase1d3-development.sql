-- Run only after explicit approval and applying 0008 on JLProject development.
-- All synthetic product, target, and audit rows are rolled back.
BEGIN;

-- Temporary owner execution access is contained in this transaction and rolled back.
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;
GRANT EXECUTE ON FUNCTION public.update_business_target(uuid, uuid, uuid, uuid, uuid,
  text, text, text, date, bigint, text), public.delete_business_target(uuid, uuid, uuid, uuid, uuid, bigint)
  TO neondb_owner;
RESET ROLE;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
DECLARE
  v_workspace uuid := '26f87a37-487d-456c-979c-e0c176df70b2';
  v_actor uuid;
  v_product uuid;
  v_target uuid;
  v_result text;
  v_r00_count bigint;
BEGIN
  SELECT count(*) INTO v_r00_count
    FROM public.workspace_memberships
    WHERE workspace_id = v_workspace AND role = 'admin' AND active = true;
  IF v_r00_count <> 1 THEN RAISE EXCEPTION 'Expected one active development administrator.'; END IF;
  SELECT auth_user_id INTO STRICT v_actor FROM public.workspace_memberships
    WHERE workspace_id = v_workspace AND role = 'admin' AND active = true;
  SELECT count(*) INTO v_r00_count FROM public.initial_schedule_revisions;

  INSERT INTO public.products (workspace_id, name, created_by, updated_by)
    VALUES (v_workspace, 'Synthetic Phase 1D.3 verification', v_actor, v_actor)
    RETURNING id INTO v_product;
  INSERT INTO public.business_targets (workspace_id, product_id, name, target_date,
    source_external_id, source_row, display_order, created_by, description, color)
    VALUES (v_workspace, v_product, 'Synthetic milestone', DATE '2026-11-10',
      NULL, NULL, 0, v_actor, 'Rollback-only verification', '#336699')
    RETURNING id INTO v_target;

  SELECT public.update_business_target(v_workspace, v_product, v_target, v_actor,
    gen_random_uuid(), 'Synthetic milestone', 'Updated synthetic description', '#4A7C59',
    DATE '2026-11-11', 1, 'Synthetic date audit verification') INTO v_result;
  IF v_result <> 'updated' OR NOT EXISTS (
    SELECT 1 FROM public.business_target_date_changes
    WHERE workspace_id = v_workspace AND product_id = v_product AND target_id = v_target
      AND previous_date = DATE '2026-11-10' AND new_date = DATE '2026-11-11'
      AND reason = 'Synthetic date audit verification' AND version_before = 1 AND version_after = 2
  ) THEN RAISE EXCEPTION 'Controlled target update or audit event failed.'; END IF;

  BEGIN
    UPDATE public.business_targets SET target_date = DATE '2026-11-12' WHERE id = v_target;
    RAISE EXCEPTION 'Direct target-date update unexpectedly succeeded.';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  IF public.update_business_target(v_workspace, v_product, v_target, v_actor,
    gen_random_uuid(), 'Synthetic milestone', 'Updated synthetic description', '#4A7C59',
    DATE '2026-11-12', 1, 'Synthetic stale version') <> 'stale' THEN
    RAISE EXCEPTION 'Stale target version was not rejected.';
  END IF;
  SELECT public.delete_business_target(v_workspace, v_product, v_target, v_actor,
    gen_random_uuid(), 2) INTO v_result;
  IF v_result <> 'deleted' THEN RAISE EXCEPTION 'Soft deletion returned status %.', v_result; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_targets WHERE id = v_target AND deleted_at IS NOT NULL)
    THEN RAISE EXCEPTION 'Soft deletion timestamp was not stored.'; END IF;
  IF (SELECT count(*) FROM public.initial_schedule_revisions) <> v_r00_count THEN
    RAISE EXCEPTION 'The R00 snapshot count changed.';
  END IF;
END;
$$;

ROLLBACK;
