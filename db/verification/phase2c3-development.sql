BEGIN;

DO $$
DECLARE
  v_workspace_id uuid := '26f87a37-487d-456c-979c-e0c176df70b2';
  v_definition_id uuid;
  v_revision_id uuid;
  v_color text;
  v_blocked boolean := false;
BEGIN
  IF current_user <> 'neondb_owner' THEN
    RAISE EXCEPTION 'Run this verification with the development migration owner.';
  END IF;
  IF NOT has_column_privilege('jlproject_worker', 'public.stage_definitions', 'color', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_definitions', 'id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_definitions', 'workspace_id', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_definitions', 'code', 'UPDATE') THEN
    RAISE EXCEPTION 'Worker stage-definition column privileges differ from the reviewed grant.';
  END IF;
  IF has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') THEN
    RAISE EXCEPTION 'Worker must not be able to update immutable R00 snapshots.';
  END IF;

  SELECT id INTO v_revision_id FROM public.initial_schedule_revisions
    WHERE workspace_id = v_workspace_id LIMIT 1;
  IF v_revision_id IS NULL THEN
    RAISE EXCEPTION 'Expected an existing development R00 snapshot for immutable-trigger verification.';
  END IF;

  INSERT INTO public.stage_definitions (workspace_id, code, color)
    VALUES (v_workspace_id, 'VERIFY-' || upper(substr(gen_random_uuid()::text, 1, 8)), '#112233')
    RETURNING id INTO v_definition_id;
  UPDATE public.stage_definitions SET color = '#AA5577'
    WHERE workspace_id = v_workspace_id AND id = v_definition_id AND color = '#112233'
    RETURNING color INTO v_color;
  IF v_color <> '#AA5577' THEN
    RAISE EXCEPTION 'Synthetic stage-definition color did not persist within the transaction.';
  END IF;

  BEGIN
    UPDATE public.initial_schedule_revisions SET snapshot = snapshot WHERE id = v_revision_id;
  EXCEPTION WHEN check_violation THEN
    v_blocked := SQLERRM = 'Initial schedule revisions are immutable.';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'R00 immutability trigger did not reject the synthetic update attempt.';
  END IF;
END;
$$;

ROLLBACK;
