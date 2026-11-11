-- Rollback-only synthetic verification for Phase 3A.5a on JLProject Development.
-- Run as jlproject_worker; all synthetic products, schedules, and revisions roll back.
BEGIN;

DO $$
DECLARE
  v_workspace_id uuid;
  v_admin_id uuid;
  v_editor_id uuid;
  v_product_id uuid;
  v_clone_id uuid;
  v_editor_clone_id uuid;
  v_source_revision_id uuid;
  v_clone_revision_id uuid;
  v_discipline_one_id uuid;
  v_discipline_two_id uuid;
  v_definition_id uuid;
  v_stage_one_id uuid;
  v_stage_two_id uuid;
  v_inherited_one_id uuid;
  v_override_id uuid;
  v_inherited_two_id uuid;
  v_clone_result jsonb;
  v_source_r00 jsonb;
  v_clone_r00 jsonb;
  v_color text;
  v_rows integer;
  v_inherited_count integer;
  v_override_count integer;
  v_changed_color_count integer;
  v_same_activity_count integer;
BEGIN
  IF current_database() <> 'neondb' OR current_user <> 'jlproject_worker' THEN
    RAISE EXCEPTION 'Verification must run as the limited Worker on JLProject Development.';
  END IF;

  IF NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'The Worker color or immutable revision grants are not correctly limited.';
  END IF;

  SELECT workspace.id, membership.auth_user_id INTO v_workspace_id, v_admin_id
  FROM public.workspaces AS workspace
  JOIN public.workspace_memberships AS membership ON membership.workspace_id = workspace.id
  WHERE workspace.name = 'JLProject' AND membership.active AND membership.role = 'admin'
  ORDER BY membership.auth_user_id LIMIT 1;
  IF v_workspace_id IS NULL OR v_admin_id IS NULL THEN
    RAISE EXCEPTION 'An active JLProject Development administrator is required.';
  END IF;

  SELECT auth_user_id INTO v_editor_id FROM public.workspace_memberships
  WHERE workspace_id = v_workspace_id AND active AND role = 'editor'
  ORDER BY auth_user_id LIMIT 1;
  IF v_editor_id IS NULL THEN RAISE EXCEPTION 'An active editor is required.'; END IF;

  INSERT INTO public.products (workspace_id, name, description, created_by, updated_by)
  VALUES (v_workspace_id, 'Synthetic 3A5a ' || replace(gen_random_uuid()::text, '-', ''),
    'Rollback-only activity color verification', v_admin_id, v_admin_id)
  RETURNING id INTO v_product_id;

  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, 'Synthetic discipline one',
    'S1' || left(replace(gen_random_uuid()::text, '-', ''), 12), '#112233', 0, v_admin_id, v_admin_id)
  RETURNING id INTO v_discipline_one_id;
  INSERT INTO public.product_disciplines
    (workspace_id, product_id, name, short_code, color, display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, 'Synthetic discipline two',
    'S2' || left(replace(gen_random_uuid()::text, '-', ''), 12), '#112233', 1, v_admin_id, v_admin_id)
  RETURNING id INTO v_discipline_two_id;

  INSERT INTO public.stage_definitions (workspace_id, code, color)
  VALUES (v_workspace_id, 'T' || left(replace(gen_random_uuid()::text, '-', ''), 12), '#445566')
  RETURNING id INTO v_definition_id;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, v_discipline_one_id, v_definition_id,
    'Synthetic stage one', 0, v_admin_id, v_admin_id)
  RETURNING id INTO v_stage_one_id;
  INSERT INTO public.discipline_stages
    (workspace_id, product_id, discipline_id, definition_id, display_name, display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, v_discipline_two_id, v_definition_id,
    'Synthetic stage two', 0, v_admin_id, v_admin_id)
  RETURNING id INTO v_stage_two_id;

  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, v_discipline_one_id, v_stage_one_id,
    'Synthetic inherited one', DATE '2026-11-11', DATE '2026-11-12', 0, v_admin_id, v_admin_id)
  RETURNING id INTO v_inherited_one_id;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, color_override, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, v_discipline_one_id, v_stage_one_id,
    'Synthetic override', DATE '2026-11-13', DATE '2026-11-14', 1, '#AA5577', v_admin_id, v_admin_id)
  RETURNING id INTO v_override_id;
  INSERT INTO public.stage_activities
    (workspace_id, product_id, discipline_id, stage_id, name, planned_start, planned_end,
     display_order, created_by, updated_by)
  VALUES (v_workspace_id, v_product_id, v_discipline_two_id, v_stage_two_id,
    'Synthetic inherited two', DATE '2026-11-15', DATE '2026-11-16', 0, v_admin_id, v_admin_id)
  RETURNING id INTO v_inherited_two_id;

  SELECT coalesce(activity.color_override, definition.color) INTO v_color
  FROM public.stage_activities AS activity
  JOIN public.stage_definitions AS definition ON definition.id = v_definition_id
  WHERE activity.id = v_inherited_one_id;
  IF v_color <> '#445566' THEN RAISE EXCEPTION 'Default stage color inheritance failed.'; END IF;
  SELECT coalesce(activity.color_override, definition.color) INTO v_color
  FROM public.stage_activities AS activity
  JOIN public.stage_definitions AS definition ON definition.id = v_definition_id
  WHERE activity.id = v_override_id;
  IF v_color <> '#AA5577' THEN RAISE EXCEPTION 'Initial custom color did not persist.'; END IF;

  UPDATE public.stage_activities SET color_override = '#BBAA22', version = version + 1,
    updated_by = v_admin_id, updated_at = now()
  WHERE workspace_id = v_workspace_id AND product_id = v_product_id
    AND discipline_id = v_discipline_one_id AND stage_id = v_stage_one_id
    AND id = v_override_id AND version = 1;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 OR (SELECT color_override FROM public.stage_activities WHERE id = v_override_id) <> '#BBAA22' THEN
    RAISE EXCEPTION 'Versioned color override update failed.';
  END IF;

  UPDATE public.stage_activities SET color_override = NULL, version = version + 1,
    updated_by = v_admin_id, updated_at = now()
  WHERE workspace_id = v_workspace_id AND product_id = v_product_id
    AND discipline_id = v_discipline_one_id AND stage_id = v_stage_one_id
    AND id = v_override_id AND version = 2;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 OR (SELECT color_override FROM public.stage_activities WHERE id = v_override_id) IS NOT NULL THEN
    RAISE EXCEPTION 'Reset to inherited stage color failed.';
  END IF;
  IF (SELECT coalesce(activity.color_override, definition.color)
      FROM public.stage_activities AS activity
      JOIN public.stage_definitions AS definition ON definition.id = v_definition_id
      WHERE activity.id = v_override_id) <> '#445566' THEN
    RAISE EXCEPTION 'Reset did not restore the effective stage color.';
  END IF;

  -- A stale expected version and a foreign workspace scope must affect zero rows.
  UPDATE public.stage_activities SET color_override = '#998877', version = version + 1
  WHERE workspace_id = v_workspace_id AND product_id = v_product_id AND id = v_override_id AND version = 2;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'A stale activity version was accepted.'; END IF;
  UPDATE public.stage_activities SET color_override = '#998877', version = version + 1
  WHERE workspace_id = gen_random_uuid() AND product_id = v_product_id AND id = v_override_id AND version = 3;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'A foreign workspace scope changed an activity.'; END IF;

  UPDATE public.stage_activities SET color_override = '#AABBCC', version = version + 1,
    updated_by = v_admin_id, updated_at = now()
  WHERE workspace_id = v_workspace_id AND product_id = v_product_id AND id = v_override_id AND version = 3;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'Current activity version did not accept the color override.'; END IF;

  UPDATE public.stage_definitions SET color = '#778899'
  WHERE workspace_id = v_workspace_id AND id = v_definition_id;
  SELECT count(*) FILTER (WHERE activity.color_override IS NULL AND
      coalesce(activity.color_override, definition.color) = '#778899'),
    count(*) FILTER (WHERE activity.color_override IS NOT NULL AND
      coalesce(activity.color_override, definition.color) = '#AABBCC')
  INTO v_inherited_count, v_override_count
  FROM public.stage_activities AS activity
  JOIN public.stage_definitions AS definition ON definition.id = v_definition_id
  WHERE activity.product_id = v_product_id;
  IF v_inherited_count <> 2 OR v_override_count <> 1 THEN
    RAISE EXCEPTION 'Stage color change did not affect exactly inherited activities.';
  END IF;

  v_source_r00 := jsonb_build_object(
    'product', jsonb_build_object('id', v_product_id, 'name', 'Synthetic source'),
    'disciplines', '[]'::jsonb, 'sourceMeta', '[]'::jsonb, 'targets', '[]'::jsonb,
    'actualStageColors', '{}'::jsonb, 'disciplineIds', '{}'::jsonb, 'stageIds', '[]'::jsonb,
    'activityIds', '{}'::jsonb, 'dependencies', '[]'::jsonb);
  INSERT INTO public.initial_schedule_revisions
    (workspace_id, product_id, import_batch_id, snapshot, created_by)
  VALUES (v_workspace_id, v_product_id, NULL, v_source_r00, v_admin_id)
  RETURNING id INTO v_source_revision_id;

  v_clone_result := public.clone_product(v_workspace_id, v_product_id, v_admin_id,
    'Synthetic 3A5a clone ' || replace(gen_random_uuid()::text, '-', ''));
  IF v_clone_result->>'status' <> 'cloned' THEN RAISE EXCEPTION 'Admin synthetic clone failed.'; END IF;
  v_clone_id := (v_clone_result->'product'->>'id')::uuid;
  v_clone_revision_id := (v_clone_result->>'revisionId')::uuid;

  SELECT count(*) FILTER (WHERE source_activity.color_override IS DISTINCT FROM clone_activity.color_override OR
      source_activity.planned_start IS DISTINCT FROM clone_activity.planned_start OR
      source_activity.planned_end IS DISTINCT FROM clone_activity.planned_end),
    count(*) FILTER (WHERE source_activity.id = clone_activity.id)
  INTO v_changed_color_count, v_same_activity_count
  FROM public.stage_activities AS source_activity
  JOIN public.stage_activities AS clone_activity
    ON clone_activity.product_id = v_clone_id AND clone_activity.name = source_activity.name
  WHERE source_activity.product_id = v_product_id;
  IF v_changed_color_count <> 0 OR v_same_activity_count <> 0 OR
     (SELECT count(*) FROM public.stage_activities WHERE product_id = v_clone_id) <> 3 THEN
    RAISE EXCEPTION 'Clone did not preserve color/date values with new activity identifiers.';
  END IF;

  SELECT snapshot INTO v_clone_r00 FROM public.initial_schedule_revisions
  WHERE id = v_clone_revision_id AND product_id = v_clone_id AND import_batch_id IS NULL AND label = 'R00';
  IF v_clone_r00 IS NULL OR v_clone_id = v_product_id OR v_clone_revision_id = v_source_revision_id OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE product_id = v_clone_id) <> 1 THEN
    RAISE EXCEPTION 'Clone did not receive an independent R00.';
  END IF;
  SELECT count(*) FILTER (WHERE activity->>'colorOverride' = '#AABBCC'),
    count(*) FILTER (WHERE activity->'colorOverride' = 'null'::jsonb)
  INTO v_override_count, v_inherited_count
  FROM jsonb_array_elements(v_clone_r00->'disciplines') AS discipline,
    jsonb_array_elements(discipline->'stages') AS stage,
    jsonb_array_elements(stage->'activities') AS activity;
  IF v_override_count <> 1 OR v_inherited_count <> 2 THEN
    RAISE EXCEPTION 'Clone R00 did not preserve custom and inherited colors.';
  END IF;

  -- Re-read source R00 after cloning; it must be unchanged and independent.
  IF (SELECT snapshot FROM public.initial_schedule_revisions WHERE id = v_source_revision_id) IS DISTINCT FROM v_source_r00 OR
     (SELECT count(*) FROM public.initial_schedule_revisions WHERE product_id = v_product_id) <> 1 THEN
    RAISE EXCEPTION 'Clone changed the source R00.';
  END IF;

  v_clone_result := public.clone_product(v_workspace_id, v_product_id, v_editor_id,
    'Synthetic editor clone ' || replace(gen_random_uuid()::text, '-', ''));
  IF v_clone_result->>'status' <> 'cloned' THEN RAISE EXCEPTION 'Active editor clone was denied.'; END IF;
  v_clone_result := public.clone_product(v_workspace_id, v_product_id, gen_random_uuid(),
    'Synthetic denied clone ' || replace(gen_random_uuid()::text, '-', ''));
  IF v_clone_result->>'status' <> 'denied' THEN RAISE EXCEPTION 'Clone accepted an unqualified actor.'; END IF;

  IF NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'INSERT') OR
     NOT has_column_privilege('jlproject_worker', 'public.stage_activities', 'color_override', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.stage_activities', 'DELETE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_start', 'UPDATE') OR
     has_column_privilege('jlproject_worker', 'public.stage_activities', 'planned_end', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') OR
     has_function_privilege('public', 'public.clone_product(uuid,uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected Worker privilege was present.';
  END IF;

  RAISE NOTICE 'Synthetic inheritance, override/reset, stage propagation, stale/workspace scope, admin/editor clone, clone/R00 preservation, and narrow Worker grants passed.';
END;
$$;

ROLLBACK;
