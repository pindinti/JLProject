-- Run only against the JLProject development branch after creating the synthetic Phase 1B.1 hierarchy.
-- The transaction always rolls back, including if an assertion fails and the connection closes.
BEGIN;

DO $$
DECLARE
  target_product uuid;
  target_discipline uuid;
  dated_stage uuid;
  target_activity uuid;
  stage_code text;
  actor uuid;
  workspace uuid;
  outcome text;
  original_start date;
  first_date date;
  last_date date;
BEGIN
  SELECT id, workspace_id INTO target_product, workspace
    FROM public.products WHERE name = 'Teste Fase 1A' LIMIT 1;
  IF target_product IS NULL THEN RAISE EXCEPTION 'Synthetic product is missing'; END IF;
  SELECT d.id, d.created_by INTO target_discipline, actor
    FROM public.product_disciplines AS d
    WHERE d.product_id = target_product AND d.name LIKE 'Teste Disciplina %'
    ORDER BY d.created_at DESC LIMIT 1;
  IF target_discipline IS NULL THEN RAISE EXCEPTION 'Synthetic discipline is missing'; END IF;
  SELECT s.id, def.code INTO dated_stage, stage_code
    FROM public.discipline_stages AS s
    JOIN public.stage_definitions AS def ON def.id = s.definition_id
    WHERE s.discipline_id = target_discipline AND s.display_name = 'Etapa datada' LIMIT 1;
  IF dated_stage IS NULL THEN RAISE EXCEPTION 'Synthetic stage is missing'; END IF;

  SELECT min(planned_start), max(planned_end) INTO first_date, last_date
    FROM public.stage_activities WHERE stage_id = dated_stage;
  IF first_date <> DATE '2026-11-01' OR last_date <> DATE '2026-11-12' THEN
    RAISE EXCEPTION 'Derived stage dates do not match the synthetic activities';
  END IF;

  outcome := public.create_discipline_stage(workspace, target_product, target_discipline,
    actor, stage_code, '#FFFFFF', 'Conflicting synthetic stage', 9);
  IF outcome <> 'conflict' THEN RAISE EXCEPTION 'Stage code accepted a conflicting color'; END IF;

  SELECT id, planned_start INTO target_activity, original_start
    FROM public.stage_activities
    WHERE stage_id = dated_stage AND name = 'Teste Atividade B' LIMIT 1;
  IF target_activity IS NULL THEN RAISE EXCEPTION 'Synthetic activity is missing'; END IF;
  BEGIN
    UPDATE public.stage_activities SET planned_start = planned_start + 1
      WHERE id = target_activity;
    RAISE EXCEPTION 'Existing planned dates were unexpectedly editable';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  IF (SELECT planned_start FROM public.stage_activities WHERE id = target_activity)
      IS DISTINCT FROM original_start THEN
    RAISE EXCEPTION 'Date changed despite immutable-date trigger';
  END IF;
END;
$$;

SELECT 'verification_passed' AS result;
ROLLBACK;
