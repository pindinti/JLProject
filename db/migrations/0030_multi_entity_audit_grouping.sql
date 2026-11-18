BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.stage_date_changes') IS NULL OR
     to_regclass('public.product_schedule_operations') IS NULL OR
     to_regclass('public.product_schedule_operation_events') IS NULL OR
     to_regclass('public.product_schedule_operation_links') IS NULL OR
     to_regprocedure('public.link_product_schedule_audit_source()') IS NULL OR
     to_regprocedure('public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)') IS NULL OR
     to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.stage_date_changes'::regclass) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.link_product_schedule_audit_source()'::regprocedure) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)'::regprocedure)
       <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_pkey' AND contype = 'p'
         AND pg_get_constraintdef(oid, true) = 'PRIMARY KEY (operation_id)') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_stage_version_unique' AND contype = 'u') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_date_changes'::regclass
         AND tgname = 'stage_date_changes_append_only' AND tgenabled IN ('O', 'A')) OR
     EXISTS (SELECT 1 FROM pg_constraint
       WHERE contype = 'f' AND confrelid = 'public.stage_date_changes'::regclass) OR
     EXISTS (SELECT 1 FROM pg_attribute
       WHERE attrelid = 'public.stage_date_changes'::regclass
         AND attname = 'event_id' AND NOT attisdropped) OR
     to_regclass('public.stage_date_changes_event_id_uidx') IS NOT NULL OR
     to_regclass('public.stage_date_changes_operation_group_idx') IS NOT NULL OR
     to_regclass('public.stage_date_changes_event_history_idx') IS NOT NULL OR
     to_regclass('public.product_schedule_operation_source_events') IS NOT NULL OR
     EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.product_schedule_operation_events'::regclass
         AND tgname = 'product_schedule_operation_events_source_links' AND NOT tgisinternal) OR
     NOT has_schema_privilege('neondb_owner', 'public', 'CREATE') OR
     (NOT (SELECT rolsuper OR rolcreaterole FROM pg_roles WHERE rolname = 'neondb_owner') AND
       NOT EXISTS (SELECT 1 FROM pg_auth_members AS membership
         JOIN pg_roles AS granted ON granted.oid = membership.roleid
         JOIN pg_roles AS member ON member.oid = membership.member
         WHERE granted.rolname = 'jlproject_date_executor' AND member.rolname = 'neondb_owner'
           AND membership.admin_option)) OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Migration 0030 prerequisites differ from the reviewed Development schema after 0029.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.product_schedule_operation_links
      WHERE source_ledger NOT IN ('activity_date_changes', 'stage_date_changes',
        'business_target_date_changes', 'calendar_reschedule_changes',
        'calendar_reschedule_reversals', 'hierarchy_movement_events',
        'schedule_deletion_events', 'reversal_of:calendar_reschedule_reversals')) THEN
    RAISE EXCEPTION 'An unreviewed specialized-ledger source link exists.';
  END IF;
END;
$$;

-- Lock the append-only audit path before adding identities or backfilling exact links.
GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
SET ROLE jlproject_date_executor;
LOCK TABLE public.stage_date_changes, public.product_schedule_state,
  public.product_schedule_operations, public.product_schedule_operation_events,
  public.product_schedule_operation_links IN ACCESS EXCLUSIVE MODE;

-- Existing operation IDs remain unchanged and become their historical event IDs.
-- New changes receive distinct event IDs while operation_id remains the group ID.
ALTER TABLE public.stage_date_changes ADD COLUMN event_id uuid;
ALTER TABLE public.stage_date_changes DISABLE TRIGGER stage_date_changes_append_only;
UPDATE public.stage_date_changes SET event_id = operation_id;
ALTER TABLE public.stage_date_changes ENABLE TRIGGER stage_date_changes_append_only;
ALTER TABLE public.stage_date_changes ALTER COLUMN event_id SET DEFAULT gen_random_uuid();
ALTER TABLE public.stage_date_changes ALTER COLUMN event_id SET NOT NULL;
CREATE UNIQUE INDEX stage_date_changes_event_id_uidx ON public.stage_date_changes (event_id);
ALTER TABLE public.stage_date_changes DROP CONSTRAINT stage_date_changes_pkey;
ALTER TABLE public.stage_date_changes ADD CONSTRAINT stage_date_changes_pkey
  PRIMARY KEY USING INDEX stage_date_changes_event_id_uidx;
CREATE INDEX stage_date_changes_operation_group_idx
  ON public.stage_date_changes (workspace_id, product_id, operation_id, event_id);
CREATE INDEX stage_date_changes_event_history_idx
  ON public.stage_date_changes (workspace_id, product_id, changed_at DESC, event_id DESC);
COMMENT ON COLUMN public.stage_date_changes.operation_id IS
  'Stable Living Schedule operation group ID; multiple stage date events may share it.';
COMMENT ON COLUMN public.stage_date_changes.event_id IS
  'Unique immutable identity for this stage date audit event. Legacy values equal the original operation ID.';

CREATE TABLE public.product_schedule_operation_source_events (
  workspace_id uuid NOT NULL,
  product_id uuid NOT NULL,
  schedule_version bigint NOT NULL,
  operation_id uuid NOT NULL,
  source_ledger text NOT NULL CHECK (source_ledger IN (
    'activity_date_changes', 'stage_date_changes', 'business_target_date_changes',
    'calendar_reschedule_changes', 'calendar_reschedule_reversals',
    'hierarchy_movement_events', 'schedule_deletion_events'
  )),
  source_operation_id uuid NOT NULL,
  source_event_id uuid NOT NULL,
  link_kind text NOT NULL CHECK (link_kind IN ('audit_detail', 'reversal_of')),
  linked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT product_schedule_operation_source_events_pkey PRIMARY KEY
    (workspace_id, product_id, schedule_version, source_ledger, link_kind, source_event_id),
  CONSTRAINT product_schedule_operation_source_events_operation_fk FOREIGN KEY
    (workspace_id, product_id, schedule_version)
    REFERENCES public.product_schedule_operations(workspace_id, product_id, schedule_version)
    ON DELETE RESTRICT
);
CREATE INDEX product_schedule_operation_source_events_group_idx
  ON public.product_schedule_operation_source_events
    (workspace_id, product_id, schedule_version, source_ledger, source_operation_id);
REVOKE ALL ON public.product_schedule_operation_source_events FROM PUBLIC, jlproject_worker;
CREATE TRIGGER product_schedule_operation_source_events_append_only
  BEFORE UPDATE OR DELETE ON public.product_schedule_operation_source_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();
CREATE TRIGGER product_schedule_operation_source_events_no_truncate
  BEFORE TRUNCATE ON public.product_schedule_operation_source_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.prevent_product_schedule_audit_mutation();

-- Backfill exact event links from the legacy group links without changing old audit/link rows.
INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  link.source_ledger, audit.operation_id, audit.operation_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.activity_date_changes AS audit
  ON audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
  AND audit.operation_id = link.source_operation_id
WHERE link.source_ledger = 'activity_date_changes' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  link.source_ledger, audit.operation_id, audit.event_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.stage_date_changes AS audit
  ON audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
  AND audit.operation_id = link.source_operation_id
WHERE link.source_ledger = 'stage_date_changes' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  link.source_ledger, audit.operation_id, audit.operation_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.business_target_date_changes AS audit
  ON audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
  AND audit.operation_id = link.source_operation_id
WHERE link.source_ledger = 'business_target_date_changes' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  link.source_ledger, audit.operation_id, audit.operation_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.hierarchy_movement_events AS audit
  ON audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
  AND audit.operation_id = link.source_operation_id
WHERE link.source_ledger = 'hierarchy_movement_events' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  link.source_ledger, audit.operation_id, audit.operation_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.schedule_deletion_events AS audit
  ON audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
  AND audit.operation_id = link.source_operation_id
WHERE link.source_ledger = 'schedule_deletion_events' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  link.source_ledger, audit.batch_operation_id, audit.date_operation_id,
  'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.calendar_reschedule_changes AS audit
  ON audit.workspace_id = link.workspace_id AND audit.product_id = link.product_id
  AND audit.date_operation_id = link.source_operation_id
WHERE link.source_ledger = 'calendar_reschedule_changes' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  'activity_date_changes', date_change.date_operation_id, date_change.date_operation_id,
  'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.calendar_reschedule_changes AS date_change
  ON date_change.workspace_id = link.workspace_id AND date_change.product_id = link.product_id
  AND date_change.date_operation_id = link.source_operation_id
JOIN public.activity_date_changes AS audit
  ON audit.workspace_id = date_change.workspace_id AND audit.product_id = date_change.product_id
  AND audit.operation_id = date_change.date_operation_id
WHERE link.source_ledger = 'calendar_reschedule_changes' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

-- Migration 0029 keyed reversal links by the batch ID, so expand each old batch link
-- to every exact reversal event and its exact original event.
INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  'calendar_reschedule_reversals', reversal.reversal_batch_operation_id,
  reversal.reversal_date_operation_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.calendar_reschedule_reversals AS reversal
  ON reversal.workspace_id = link.workspace_id AND reversal.product_id = link.product_id
  AND reversal.reversal_batch_operation_id = link.source_operation_id
WHERE link.source_ledger = 'calendar_reschedule_reversals' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  'activity_date_changes', reversal.reversal_date_operation_id,
  reversal.reversal_date_operation_id, 'audit_detail', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.calendar_reschedule_reversals AS reversal
  ON reversal.workspace_id = link.workspace_id AND reversal.product_id = link.product_id
  AND reversal.reversal_batch_operation_id = link.source_operation_id
JOIN public.activity_date_changes AS audit
  ON audit.workspace_id = reversal.workspace_id AND audit.product_id = reversal.product_id
  AND audit.operation_id = reversal.reversal_date_operation_id
WHERE link.source_ledger = 'calendar_reschedule_reversals' AND link.link_kind = 'audit_detail'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind, linked_at
)
SELECT link.workspace_id, link.product_id, link.schedule_version, link.operation_id,
  'calendar_reschedule_changes', reversal.original_batch_operation_id,
  reversal.original_date_operation_id, 'reversal_of', link.linked_at
FROM public.product_schedule_operation_links AS link
JOIN public.calendar_reschedule_reversals AS reversal
  ON reversal.workspace_id = link.workspace_id AND reversal.product_id = link.product_id
  AND reversal.reversal_batch_operation_id = link.operation_id
  AND reversal.original_batch_operation_id = link.source_operation_id
WHERE link.link_kind = 'reversal_of'
  AND link.source_ledger IN ('calendar_reschedule_reversals',
    'reversal_of:calendar_reschedule_reversals')
ON CONFLICT DO NOTHING;

CREATE FUNCTION public.link_product_schedule_operation_source_events()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'stage_date_changes', audit.operation_id, audit.event_id, 'audit_detail'
    FROM public.stage_date_changes AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'activity_date_changes', audit.operation_id, audit.operation_id, 'audit_detail'
    FROM public.activity_date_changes AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'business_target_date_changes', audit.operation_id, audit.operation_id, 'audit_detail'
    FROM public.business_target_date_changes AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'hierarchy_movement_events', audit.operation_id, audit.operation_id, 'audit_detail'
    FROM public.hierarchy_movement_events AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'schedule_deletion_events', audit.operation_id, audit.operation_id, 'audit_detail'
    FROM public.schedule_deletion_events AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'calendar_reschedule_changes', audit.batch_operation_id, audit.date_operation_id, 'audit_detail'
    FROM public.calendar_reschedule_changes AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.batch_operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'calendar_reschedule_reversals', audit.reversal_batch_operation_id,
      audit.reversal_date_operation_id, 'audit_detail'
    FROM public.calendar_reschedule_reversals AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.reversal_batch_operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;

  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) SELECT NEW.workspace_id, NEW.product_id, NEW.schedule_version, NEW.operation_id,
      'calendar_reschedule_changes', audit.original_batch_operation_id,
      audit.original_date_operation_id, 'reversal_of'
    FROM public.calendar_reschedule_reversals AS audit
    WHERE audit.workspace_id = NEW.workspace_id AND audit.product_id = NEW.product_id
      AND audit.reversal_batch_operation_id = NEW.operation_id
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.link_product_schedule_operation_source_events() FROM PUBLIC, jlproject_worker;
CREATE TRIGGER product_schedule_operation_events_source_links
  AFTER INSERT ON public.product_schedule_operation_events
  FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_operation_source_events();

CREATE OR REPLACE FUNCTION public.link_product_schedule_audit_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_row jsonb;
  v_workspace_id uuid;
  v_product_id uuid;
  v_source_operation_id uuid;
  v_source_event_id uuid;
  v_original_operation_id uuid;
  v_original_event_id uuid;
  v_legacy_source_operation_id uuid;
  v_operation public.product_schedule_operations%ROWTYPE;
BEGIN
  v_row := to_jsonb(NEW);
  v_workspace_id := (v_row->>'workspace_id')::uuid;
  v_product_id := (v_row->>'product_id')::uuid;
  CASE TG_TABLE_NAME
    WHEN 'stage_date_changes' THEN
      v_source_operation_id := (v_row->>'operation_id')::uuid;
      v_source_event_id := (v_row->>'event_id')::uuid;
    WHEN 'activity_date_changes' THEN
      v_source_operation_id := (v_row->>'operation_id')::uuid;
      v_source_event_id := (v_row->>'operation_id')::uuid;
    WHEN 'business_target_date_changes' THEN
      v_source_operation_id := (v_row->>'operation_id')::uuid;
      v_source_event_id := (v_row->>'operation_id')::uuid;
    WHEN 'hierarchy_movement_events' THEN
      v_source_operation_id := (v_row->>'operation_id')::uuid;
      v_source_event_id := (v_row->>'operation_id')::uuid;
    WHEN 'schedule_deletion_events' THEN
      v_source_operation_id := (v_row->>'operation_id')::uuid;
      v_source_event_id := (v_row->>'operation_id')::uuid;
    WHEN 'calendar_reschedule_changes' THEN
      v_source_operation_id := (v_row->>'batch_operation_id')::uuid;
      v_source_event_id := (v_row->>'date_operation_id')::uuid;
    WHEN 'calendar_reschedule_reversals' THEN
      v_source_operation_id := (v_row->>'reversal_batch_operation_id')::uuid;
      v_source_event_id := (v_row->>'reversal_date_operation_id')::uuid;
      v_original_operation_id := (v_row->>'original_batch_operation_id')::uuid;
      v_original_event_id := (v_row->>'original_date_operation_id')::uuid;
    ELSE
      RAISE EXCEPTION 'Unsupported schedule audit source table: %', TG_TABLE_NAME;
  END CASE;

  v_legacy_source_operation_id := COALESCE(
    NULLIF(v_row->>'operation_id', '')::uuid,
    NULLIF(v_row->>'date_operation_id', '')::uuid,
    NULLIF(v_row->>'reversal_batch_operation_id', '')::uuid,
    NULLIF(v_row->>'reversal_date_operation_id', '')::uuid
  );
  IF TG_TABLE_NAME = 'schedule_deletion_events' THEN
    PERFORM public.write_product_schedule_operation_event(
      v_workspace_id, v_product_id, (v_row->>'actor_id')::uuid,
      (v_row->>'operation_id')::uuid, 'schedule_deleted', v_row->>'reason', NULL,
      v_row->>'target_kind', (v_row->>'target_id')::uuid, 'schedule_deleted',
      COALESCE(v_row->'affected_items', '{}'::jsonb), '{}'::jsonb,
      COALESCE(v_row->'affected_items', '{}'::jsonb), '{}'::jsonb
    );
  END IF;
  SELECT * INTO v_operation FROM public.product_schedule_operations AS operation
    WHERE operation.workspace_id = v_workspace_id AND operation.product_id = v_product_id
      AND operation.transaction_id = pg_current_xact_id();
  IF NOT FOUND THEN RETURN NEW; END IF;

  INSERT INTO public.product_schedule_operation_links (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, link_kind
  ) VALUES (
    v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
    TG_TABLE_NAME, v_legacy_source_operation_id, 'audit_detail'
  ) ON CONFLICT DO NOTHING;
  INSERT INTO public.product_schedule_operation_source_events (
    workspace_id, product_id, schedule_version, operation_id, source_ledger,
    source_operation_id, source_event_id, link_kind
  ) VALUES (
    v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
    TG_TABLE_NAME, v_source_operation_id, v_source_event_id, 'audit_detail'
  ) ON CONFLICT DO NOTHING;

  IF TG_TABLE_NAME IN ('calendar_reschedule_changes', 'calendar_reschedule_reversals') THEN
    INSERT INTO public.product_schedule_operation_source_events (
      workspace_id, product_id, schedule_version, operation_id, source_ledger,
      source_operation_id, source_event_id, link_kind
    ) VALUES (
      v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
      'activity_date_changes', v_source_event_id, v_source_event_id, 'audit_detail'
    ) ON CONFLICT DO NOTHING;
  END IF;

  IF v_original_operation_id IS NOT NULL AND v_original_event_id IS NOT NULL THEN
    INSERT INTO public.product_schedule_operation_links (
      workspace_id, product_id, schedule_version, operation_id, source_ledger,
      source_operation_id, link_kind
    ) VALUES (
      v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
      'reversal_of:' || TG_TABLE_NAME, v_original_operation_id, 'reversal_of'
    ) ON CONFLICT DO NOTHING;
    INSERT INTO public.product_schedule_operation_source_events (
      workspace_id, product_id, schedule_version, operation_id, source_ledger,
      source_operation_id, source_event_id, link_kind
    ) VALUES (
      v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
      'calendar_reschedule_changes', v_original_operation_id, v_original_event_id, 'reversal_of'
    ) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DO $history$
DECLARE
  v_definition text := pg_get_functiondef(
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure);
  v_old_event_id text := quote_literal('stage-date:') || ' || change.operation_id::text';
  v_new_event_id text := quote_literal('stage-date:') || ' || change.event_id::text';
  v_old_item constant text := $$jsonb_build_object('kind', 'stage', 'id', stage.id::text, 'name', stage.display_name,$$;
  v_new_item constant text := $$jsonb_build_object('kind', 'stage', 'id', stage.id::text, 'name', stage.display_name,
        'operationId', change.operation_id::text,$$;
BEGIN
  IF position(v_old_event_id IN v_definition) = 0 OR
     position(v_new_event_id IN v_definition) > 0 OR
     position(v_old_item IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Product history function differs from the reviewed 0028 stage-date definition.';
  END IF;
  v_definition := replace(v_definition, v_old_event_id, v_new_event_id);
  v_definition := replace(v_definition, v_old_item, v_new_item);
  EXECUTE v_definition;
END;
$history$;

CREATE OR REPLACE FUNCTION public.list_product_schedule_operations(
  p_workspace_id uuid,
  p_product_id uuid,
  p_actor_id uuid,
  p_before_version bigint,
  p_limit integer
) RETURNS TABLE (
  schedule_version bigint,
  operation_id uuid,
  actor_id uuid,
  occurred_at timestamptz,
  operation_type text,
  justification text,
  reversal_of_operation_id uuid,
  events jsonb,
  source_operations jsonb
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  SELECT operation.schedule_version, operation.operation_id, operation.actor_id,
    operation.occurred_at, operation.operation_type, operation.justification,
    operation.reversal_of_operation_id,
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'eventId', event.event_id, 'entityType', event.entity_type, 'entityId', event.entity_id,
      'changeType', event.change_type, 'parentBefore', event.parent_before,
      'parentAfter', event.parent_after, 'previousValues', event.previous_values,
      'newValues', event.new_values
    ) ORDER BY event.event_id) FROM public.product_schedule_operation_events AS event
      WHERE event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
        AND event.schedule_version = operation.schedule_version), '[]'::jsonb) AS events,
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'ledger', source.source_ledger, 'operationId', source.source_operation_id,
      'eventId', source.source_event_id, 'kind', source.link_kind
    ) ORDER BY source.source_ledger, source.source_operation_id, source.source_event_id,
      source.link_kind)
      FROM public.product_schedule_operation_source_events AS source
      WHERE source.workspace_id = operation.workspace_id AND source.product_id = operation.product_id
        AND source.schedule_version = operation.schedule_version), '[]'::jsonb) AS source_operations
  FROM public.product_schedule_operations AS operation
  WHERE operation.workspace_id = p_workspace_id AND operation.product_id = p_product_id
    AND (p_before_version IS NULL OR operation.schedule_version < p_before_version)
    AND p_limit BETWEEN 1 AND 100
    AND EXISTS (SELECT 1 FROM public.workspace_memberships AS membership
      WHERE membership.workspace_id = p_workspace_id AND membership.auth_user_id = p_actor_id
        AND membership.active AND membership.role IN ('admin', 'editor', 'viewer'))
  ORDER BY operation.schedule_version DESC
  LIMIT p_limit
$$;

REVOKE ALL ON FUNCTION public.link_product_schedule_operation_source_events() FROM PUBLIC, jlproject_worker;
REVOKE ALL ON FUNCTION public.link_product_schedule_audit_source() FROM PUBLIC, jlproject_worker;
REVOKE ALL ON FUNCTION public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)
  TO jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

DO $$
BEGIN
  IF (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.stage_date_changes'::regclass) <> 'jlproject_date_executor' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class
       WHERE oid = 'public.product_schedule_operation_source_events'::regclass) <> 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_pkey' AND contype = 'p'
         AND pg_get_constraintdef(oid, true) = 'PRIMARY KEY (event_id)') OR
     EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass AND contype IN ('p', 'u')
         AND pg_get_constraintdef(oid, true) IN
           ('PRIMARY KEY (operation_id)', 'UNIQUE (operation_id)')) OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.stage_date_changes'::regclass
         AND conname = 'stage_date_changes_stage_version_unique' AND contype = 'u') OR
     to_regclass('public.stage_date_changes_operation_group_idx') IS NULL OR
     to_regclass('public.stage_date_changes_event_history_idx') IS NULL OR
     (SELECT count(*) FROM public.stage_date_changes) <>
       (SELECT count(DISTINCT event_id) FROM public.stage_date_changes) OR
     EXISTS (SELECT 1 FROM public.stage_date_changes WHERE event_id IS NULL) OR
     NOT EXISTS (SELECT 1 FROM pg_attribute
       WHERE attrelid = 'public.stage_date_changes'::regclass
         AND attname = 'event_id' AND NOT attisdropped AND attnotnull) OR
     NOT EXISTS (SELECT 1 FROM pg_attrdef AS default_value
       JOIN pg_attribute AS attribute ON attribute.attrelid = default_value.adrelid
         AND attribute.attnum = default_value.adnum
       WHERE default_value.adrelid = 'public.stage_date_changes'::regclass
         AND attribute.attname = 'event_id'
         AND pg_get_expr(default_value.adbin, default_value.adrelid) LIKE '%gen_random_uuid%') OR
     NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.product_schedule_operation_source_events'::regclass
         AND conname = 'product_schedule_operation_source_events_pkey' AND contype = 'p'
         AND pg_get_constraintdef(oid, true) =
           'PRIMARY KEY (workspace_id, product_id, schedule_version, source_ledger, link_kind, source_event_id)') OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.product_schedule_operation_events'::regclass
         AND tgname = 'product_schedule_operation_events_source_links' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.product_schedule_operation_source_events'::regclass
         AND tgname = 'product_schedule_operation_source_events_append_only' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.product_schedule_operation_source_events'::regclass
         AND tgname = 'product_schedule_operation_source_events_no_truncate' AND tgenabled IN ('O', 'A')) OR
     NOT EXISTS (SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.stage_date_changes'::regclass
         AND tgname = 'stage_date_changes_append_only' AND tgenabled IN ('O', 'A')) OR
     position('change.event_id' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 OR
     position('product_schedule_operation_source_events' IN pg_get_functiondef(
       'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)'::regprocedure)) = 0 OR
     position('reversal_date_operation_id' IN pg_get_functiondef(
       'public.link_product_schedule_audit_source()'::regprocedure)) = 0 OR
     EXISTS (SELECT 1 FROM pg_proc AS function
       WHERE function.oid IN (
         'public.link_product_schedule_operation_source_events()'::regprocedure,
         'public.link_product_schedule_audit_source()'::regprocedure,
         'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)'::regprocedure,
         'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure
       ) AND (
         function.proowner <> (SELECT oid FROM pg_roles WHERE rolname = 'jlproject_date_executor') OR
         NOT function.prosecdef OR
         NOT (function.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'])
       )) OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'SELECT') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'INSERT') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'UPDATE') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'DELETE') OR
     has_table_privilege('jlproject_worker',
       'public.product_schedule_operation_source_events', 'TRUNCATE') OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.list_product_schedule_operations(uuid,uuid,uuid,bigint,integer)', 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.link_product_schedule_audit_source()', 'EXECUTE') OR
     has_function_privilege('public',
       'public.link_product_schedule_audit_source()', 'EXECUTE') OR
     has_function_privilege('jlproject_worker',
       'public.link_product_schedule_operation_source_events()', 'EXECUTE') OR
     has_function_privilege('public',
       'public.link_product_schedule_operation_source_events()', 'EXECUTE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') THEN
    RAISE EXCEPTION 'Migration 0030 postconditions or least-privilege boundaries are incorrect.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.stage_date_changes AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger AND source.source_operation_id = audit.operation_id
      AND source.source_event_id = audit.event_id
      AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'stage_date_changes'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.activity_date_changes AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger AND source.source_operation_id = audit.operation_id
      AND source.source_event_id = audit.operation_id
      AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'activity_date_changes'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.business_target_date_changes AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger AND source.source_operation_id = audit.operation_id
      AND source.source_event_id = audit.operation_id
      AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'business_target_date_changes'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.hierarchy_movement_events AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger AND source.source_operation_id = audit.operation_id
      AND source.source_event_id = audit.operation_id
      AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'hierarchy_movement_events'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.schedule_deletion_events AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger AND source.source_operation_id = audit.operation_id
      AND source.source_event_id = audit.operation_id
      AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'schedule_deletion_events'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.calendar_reschedule_changes AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.date_operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger
      AND source.source_operation_id = audit.batch_operation_id
      AND source.source_event_id = audit.date_operation_id
      AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'calendar_reschedule_changes'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.calendar_reschedule_reversals AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.reversal_batch_operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = legacy.source_ledger
      AND source.source_operation_id = audit.reversal_batch_operation_id
      AND source.source_event_id = audit.reversal_date_operation_id AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'calendar_reschedule_reversals'
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.calendar_reschedule_reversals AS reversal
      ON reversal.workspace_id = legacy.workspace_id AND reversal.product_id = legacy.product_id
      AND reversal.reversal_batch_operation_id = legacy.operation_id
      AND reversal.original_batch_operation_id = legacy.source_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = 'calendar_reschedule_changes'
      AND source.source_operation_id = reversal.original_batch_operation_id
      AND source.source_event_id = reversal.original_date_operation_id
      AND source.link_kind = 'reversal_of'
    WHERE legacy.link_kind = 'reversal_of'
      AND legacy.source_ledger IN ('calendar_reschedule_reversals',
        'reversal_of:calendar_reschedule_reversals')
      AND source.source_event_id IS NULL
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.calendar_reschedule_changes AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.date_operation_id = legacy.source_operation_id
    LEFT JOIN public.activity_date_changes AS activity_audit
      ON activity_audit.workspace_id = audit.workspace_id AND activity_audit.product_id = audit.product_id
      AND activity_audit.operation_id = audit.date_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = 'activity_date_changes'
      AND source.source_operation_id = audit.date_operation_id
      AND source.source_event_id = audit.date_operation_id AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'calendar_reschedule_changes'
      AND (activity_audit.operation_id IS NULL OR source.source_event_id IS NULL)
    UNION ALL
    SELECT 1
    FROM public.product_schedule_operation_links AS legacy
    JOIN public.calendar_reschedule_reversals AS audit
      ON audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
      AND audit.reversal_batch_operation_id = legacy.source_operation_id
    LEFT JOIN public.activity_date_changes AS activity_audit
      ON activity_audit.workspace_id = audit.workspace_id AND activity_audit.product_id = audit.product_id
      AND activity_audit.operation_id = audit.reversal_date_operation_id
    LEFT JOIN public.product_schedule_operation_source_events AS source
      ON source.workspace_id = legacy.workspace_id AND source.product_id = legacy.product_id
      AND source.schedule_version = legacy.schedule_version AND source.operation_id = legacy.operation_id
      AND source.source_ledger = 'activity_date_changes'
      AND source.source_operation_id = audit.reversal_date_operation_id
      AND source.source_event_id = audit.reversal_date_operation_id AND source.link_kind = 'audit_detail'
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'calendar_reschedule_reversals'
      AND (activity_audit.operation_id IS NULL OR source.source_event_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'Migration 0030 left an ambiguous or missing specialized audit source link.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'stage_date_changes'
      AND NOT EXISTS (SELECT 1 FROM public.stage_date_changes AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'activity_date_changes'
      AND NOT EXISTS (SELECT 1 FROM public.activity_date_changes AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'business_target_date_changes'
      AND NOT EXISTS (SELECT 1 FROM public.business_target_date_changes AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'hierarchy_movement_events'
      AND NOT EXISTS (SELECT 1 FROM public.hierarchy_movement_events AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'schedule_deletion_events'
      AND NOT EXISTS (SELECT 1 FROM public.schedule_deletion_events AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'calendar_reschedule_changes'
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_changes AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.date_operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'audit_detail' AND legacy.source_ledger = 'calendar_reschedule_reversals'
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_reversals AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.reversal_batch_operation_id = legacy.source_operation_id)
    UNION ALL
    SELECT 1 FROM public.product_schedule_operation_links AS legacy
    WHERE legacy.link_kind = 'reversal_of'
      AND legacy.source_ledger IN ('calendar_reschedule_reversals',
        'reversal_of:calendar_reschedule_reversals')
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_reversals AS audit
        WHERE audit.workspace_id = legacy.workspace_id AND audit.product_id = legacy.product_id
          AND audit.reversal_batch_operation_id = legacy.operation_id
          AND audit.original_batch_operation_id = legacy.source_operation_id)
  ) THEN
    RAISE EXCEPTION 'Migration 0030 found a dangling legacy audit source link.';
  END IF;
END;
$$;

COMMIT;
