BEGIN;

DO $$
DECLARE
  v_revision_id uuid;
BEGIN
  IF current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION 'R00 immutability verification requires the approved migration owner role.';
  END IF;
  SELECT id INTO v_revision_id FROM public.initial_schedule_revisions
    WHERE label = 'R00' ORDER BY created_at LIMIT 1;
  IF v_revision_id IS NULL THEN RAISE EXCEPTION 'No R00 snapshot is available to verify.'; END IF;

  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = snapshot WHERE id = v_revision_id;
    RAISE EXCEPTION 'R00 update unexpectedly succeeded.' USING ERRCODE = 'P0001';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'R00 update rejected by its immutability trigger.';
  END;

  BEGIN
    DELETE FROM public.initial_schedule_revisions WHERE id = v_revision_id;
    RAISE EXCEPTION 'R00 delete unexpectedly succeeded.' USING ERRCODE = 'P0001';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'R00 delete rejected by its immutability trigger.';
  END;
END;
$$;

ROLLBACK;
