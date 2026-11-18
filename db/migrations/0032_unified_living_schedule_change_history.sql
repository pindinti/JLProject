BEGIN;

DO $preflight$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regclass('public.product_schedule_operation_source_events') IS NULL OR
     to_regclass('public.product_schedule_operation_events') IS NULL OR
     to_regclass('public.product_schedule_operations') IS NULL OR
     to_regclass('public.product_schedule_operations_history_time_idx') IS NOT NULL OR
     to_regclass('public.import_batches') IS NULL OR
     to_regclass('public.stage_date_changes') IS NULL OR
     to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NULL OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT') OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.products'::regclass) <> 'neondb_owner' OR
     (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.import_batches'::regclass) <> 'neondb_owner' OR
     to_regprocedure('public.link_product_schedule_history_provenance()') IS NOT NULL OR
     EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN
       ('products_z_history_source_link', 'import_batches_z_history_source_link') AND NOT tgisinternal) OR
     position('public.hierarchy_movement_events' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 OR
     position('change.event_id::text' IN pg_get_functiondef(
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'Unified product history prerequisites or privilege boundaries differ from the reviewed Development state.';
  END IF;
END;
$preflight$;

GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner WITH INHERIT FALSE, SET TRUE;
SET ROLE jlproject_date_executor;

CREATE INDEX product_schedule_operations_history_time_idx
  ON public.product_schedule_operations (workspace_id, product_id, occurred_at DESC,
    (('operation:'::text || operation_id::text) COLLATE "C") DESC);

DO $migration$
DECLARE
  v_signature constant text :=
    'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)';
  v_definition text := pg_get_functiondef(v_signature::regprocedure);
  v_anchor constant text := '  ), eligible AS MATERIALIZED (';
  v_replacement constant text := $feed$
  ), candidate_operations AS MATERIALIZED (
    SELECT operation.*
    FROM public.product_schedule_operations AS operation
    WHERE operation.workspace_id = p_workspace_id AND operation.product_id = p_product_id
      AND (p_before_at IS NULL OR
        (operation.occurred_at, ('operation:' || operation.operation_id::text) COLLATE "C") <
        (p_before_at, p_before_id COLLATE "C"))
    ORDER BY operation.occurred_at DESC, ('operation:' || operation.operation_id::text) COLLATE "C" DESC
    LIMIT p_limit + 1
  ), source_event_entities AS (
    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'products'::text AS entity_type,
      product.id AS entity_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.products AS product ON product.workspace_id = source.workspace_id
      AND product.id = source.product_id AND product.id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'products' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'import_batches'::text, batch.id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.import_batches AS batch ON batch.workspace_id = source.workspace_id
      AND batch.product_id = source.product_id AND batch.id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'import_batches' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'discipline_stages'::text AS entity_type,
      audit.stage_id AS entity_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.stage_date_changes AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id AND audit.event_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'stage_date_changes' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'stage_activities'::text, audit.activity_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.activity_date_changes AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id AND audit.operation_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'activity_date_changes' AND source.link_kind = 'audit_detail'
      AND NOT EXISTS (SELECT 1 FROM public.product_schedule_operation_source_events AS batch_source
        WHERE batch_source.workspace_id = source.workspace_id AND batch_source.product_id = source.product_id
          AND batch_source.operation_id = source.operation_id
          AND batch_source.source_event_id = source.source_event_id
          AND batch_source.source_ledger IN ('calendar_reschedule_changes', 'calendar_reschedule_reversals')
          AND batch_source.link_kind = 'audit_detail')

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'business_targets'::text, audit.target_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.business_target_date_changes AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id AND audit.operation_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'business_target_date_changes' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind,
      CASE audit.item_kind WHEN 'discipline' THEN 'product_disciplines'
        WHEN 'stage' THEN 'discipline_stages' ELSE 'stage_activities' END,
      audit.item_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.hierarchy_movement_events AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id AND audit.operation_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'hierarchy_movement_events' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind,
      CASE audit.target_kind WHEN 'discipline' THEN 'product_disciplines'
        WHEN 'stage' THEN 'discipline_stages' ELSE 'stage_activities' END,
      audit.target_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.schedule_deletion_events AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id AND audit.operation_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'schedule_deletion_events' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'stage_activities'::text, audit.activity_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.calendar_reschedule_changes AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id AND audit.date_operation_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'calendar_reschedule_changes' AND source.link_kind = 'audit_detail'

    UNION ALL

    SELECT source.workspace_id, source.product_id, source.schedule_version,
      source.operation_id, source.source_ledger, source.source_operation_id,
      source.source_event_id, source.link_kind, 'stage_activities'::text, audit.activity_id
    FROM public.product_schedule_operation_source_events AS source
    JOIN public.calendar_reschedule_reversals AS audit ON audit.workspace_id = source.workspace_id
      AND audit.product_id = source.product_id
      AND audit.reversal_date_operation_id = source.source_event_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
      AND source.source_ledger = 'calendar_reschedule_reversals' AND source.link_kind = 'audit_detail'
  ), generic_entity_counts AS (
    SELECT event.workspace_id, event.product_id, event.operation_id,
      event.entity_type, event.entity_id, count(*) AS detail_count
    FROM public.product_schedule_operation_events AS event
    JOIN candidate_operations AS candidate ON candidate.workspace_id = event.workspace_id
      AND candidate.product_id = event.product_id AND candidate.operation_id = event.operation_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id
    GROUP BY event.workspace_id, event.product_id, event.operation_id,
      event.entity_type, event.entity_id
  ), source_entity_counts AS (
    SELECT source.workspace_id, source.product_id, source.operation_id,
      source.entity_type, source.entity_id,
      count(DISTINCT (source.source_ledger, source.source_event_id)) AS source_count,
      min(source.source_ledger) AS source_ledger
    FROM source_event_entities AS source
    JOIN candidate_operations AS candidate ON candidate.workspace_id = source.workspace_id
      AND candidate.product_id = source.product_id AND candidate.operation_id = source.operation_id
    WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
    GROUP BY source.workspace_id, source.product_id, source.operation_id,
      source.entity_type, source.entity_id
  ), exact_entity_sources AS (
    SELECT generic.workspace_id, generic.product_id, generic.operation_id,
      generic.entity_type, generic.entity_id, source.source_ledger
    FROM generic_entity_counts AS generic
    JOIN source_entity_counts AS source ON source.workspace_id = generic.workspace_id
      AND source.product_id = generic.product_id AND source.operation_id = generic.operation_id
      AND source.entity_type = generic.entity_type AND source.entity_id = generic.entity_id
    WHERE generic.detail_count = 1 AND source.source_count = 1
  ), generic_details AS (
    SELECT operation.workspace_id, operation.product_id, operation.schedule_version,
      operation.operation_id, operation.actor_id, operation.occurred_at,
      operation.operation_type, operation.justification,
      operation.reversal_of_operation_id, event.event_id, event.entity_type,
      event.entity_id, event.change_type, event.parent_before, event.parent_after,
      source.source_ledger,
      CASE source.source_ledger
        WHEN 'activity_date_changes' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
        WHEN 'calendar_reschedule_changes' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
        WHEN 'calendar_reschedule_reversals' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
        WHEN 'stage_date_changes' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
        WHEN 'business_target_date_changes' THEN event.previous_values - ARRAY['target_date']
        WHEN 'hierarchy_movement_events' THEN event.previous_values - ARRAY['display_order', 'discipline_id', 'stage_id']
        ELSE event.previous_values
      END AS previous_values,
      CASE source.source_ledger
        WHEN 'activity_date_changes' THEN event.new_values - ARRAY['planned_start', 'planned_end']
        WHEN 'calendar_reschedule_changes' THEN event.new_values - ARRAY['planned_start', 'planned_end']
        WHEN 'calendar_reschedule_reversals' THEN event.new_values - ARRAY['planned_start', 'planned_end']
        WHEN 'stage_date_changes' THEN event.new_values - ARRAY['planned_start', 'planned_end']
        WHEN 'business_target_date_changes' THEN event.new_values - ARRAY['target_date']
        WHEN 'hierarchy_movement_events' THEN event.new_values - ARRAY['display_order', 'discipline_id', 'stage_id']
        ELSE event.new_values
      END AS new_values
    FROM public.product_schedule_operations AS operation
    JOIN public.product_schedule_operation_events AS event
      ON event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
      AND event.schedule_version = operation.schedule_version
    JOIN candidate_operations AS candidate ON candidate.workspace_id = operation.workspace_id
      AND candidate.product_id = operation.product_id AND candidate.operation_id = operation.operation_id
    LEFT JOIN exact_entity_sources AS source ON source.workspace_id = event.workspace_id
      AND source.product_id = event.product_id AND source.operation_id = event.operation_id
      AND source.entity_type = event.entity_type AND source.entity_id = event.entity_id
    WHERE operation.workspace_id = p_workspace_id AND operation.product_id = p_product_id
      AND NOT (source.source_ledger IS NOT NULL AND
        ((position('dates_changed' IN event.change_type) > 0 OR
          event.change_type LIKE '%_moved') AND
         (CASE source.source_ledger
            WHEN 'activity_date_changes' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
            WHEN 'calendar_reschedule_changes' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
            WHEN 'calendar_reschedule_reversals' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
            WHEN 'stage_date_changes' THEN event.previous_values - ARRAY['planned_start', 'planned_end']
            WHEN 'business_target_date_changes' THEN event.previous_values - ARRAY['target_date']
            WHEN 'hierarchy_movement_events' THEN event.previous_values - ARRAY['display_order', 'discipline_id', 'stage_id']
            ELSE event.previous_values END) = '{}'::jsonb AND
         (CASE source.source_ledger
            WHEN 'activity_date_changes' THEN event.new_values - ARRAY['planned_start', 'planned_end']
            WHEN 'calendar_reschedule_changes' THEN event.new_values - ARRAY['planned_start', 'planned_end']
            WHEN 'calendar_reschedule_reversals' THEN event.new_values - ARRAY['planned_start', 'planned_end']
            WHEN 'stage_date_changes' THEN event.new_values - ARRAY['planned_start', 'planned_end']
            WHEN 'business_target_date_changes' THEN event.new_values - ARRAY['target_date']
            WHEN 'hierarchy_movement_events' THEN event.new_values - ARRAY['display_order', 'discipline_id', 'stage_id']
            ELSE event.new_values END) = '{}'::jsonb))
  ), generic_operation_feed AS (
    SELECT 'operation:' || detail.operation_id::text AS event_id,
      detail.occurred_at, detail.actor_id, 'living_schedule_operation'::text AS event_type,
      NULL::jsonb AS item, detail.justification AS justification,
      NULL::jsonb AS before_details, NULL::jsonb AS after_details,
      COALESCE(jsonb_agg(jsonb_build_object('kind',
        CASE detail.entity_type WHEN 'product_disciplines' THEN 'discipline'
          WHEN 'discipline_stages' THEN 'stage' WHEN 'stage_activities' THEN 'activity'
          WHEN 'business_targets' THEN 'business_target' WHEN 'products' THEN 'product'
          ELSE 'schedule_item' END,
        'id', detail.entity_id::text,
        'name', COALESCE(detail.new_values->>'name', detail.previous_values->>'name'),
        'hierarchy', jsonb_build_object('parentBefore', detail.parent_before,
          'parentAfter', detail.parent_after)) ORDER BY detail.event_id), '[]'::jsonb) AS affected_items,
      detail.operation_id, detail.operation_type, detail.reversal_of_operation_id,
      jsonb_agg(jsonb_build_object('eventId', detail.event_id::text,
        'source', 'living_schedule', 'eventType', 'schedule_operation_detail',
        'entityType', detail.entity_type, 'entityId', detail.entity_id::text,
        'changeType', detail.change_type,
        'item', jsonb_build_object('kind',
          CASE detail.entity_type WHEN 'product_disciplines' THEN 'discipline'
            WHEN 'discipline_stages' THEN 'stage' WHEN 'stage_activities' THEN 'activity'
            WHEN 'business_targets' THEN 'business_target' WHEN 'products' THEN 'product'
            ELSE 'schedule_item' END,
          'id', detail.entity_id::text,
          'name', COALESCE(detail.new_values->>'name', detail.previous_values->>'name')),
        'parentBefore', detail.parent_before, 'parentAfter', detail.parent_after,
        'before', detail.previous_values, 'after', detail.new_values)
        ORDER BY detail.event_id) AS details
    FROM generic_details AS detail
    GROUP BY detail.operation_id, detail.occurred_at, detail.actor_id,
      detail.operation_type, detail.justification, detail.reversal_of_operation_id
  ), linked_specialized_feed AS (
    SELECT event.*, link.operation_id,
      operation.operation_type, operation.reversal_of_operation_id,
      jsonb_build_array(jsonb_build_object('eventId', event.event_id,
        'source', 'specialized', 'eventType', event.event_type,
        'item', event.item, 'justification', event.justification,
        'before', event.before_details, 'after', event.after_details,
        'affectedItems', event.affected_items)) AS details
    FROM event_feed AS event
    LEFT JOIN LATERAL (
      SELECT source.operation_id
      FROM source_event_entities AS source
      WHERE source.workspace_id = p_workspace_id AND source.product_id = p_product_id
        AND source.link_kind = 'audit_detail'
        AND CASE event.event_type
          WHEN 'activity_dates_changed' THEN source.source_ledger = 'activity_date_changes'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'product_created' THEN source.source_ledger = 'products'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'schedule_imported' THEN source.source_ledger = 'import_batches'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'stage_dates_changed' THEN source.source_ledger = 'stage_date_changes'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'business_target_date_changed' THEN source.source_ledger = 'business_target_date_changes'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'hierarchy_moved' THEN source.source_ledger = 'hierarchy_movement_events'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'schedule_hierarchy_deleted' THEN source.source_ledger = 'schedule_deletion_events'
            AND source.source_event_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'calendar_rescheduled' THEN source.source_ledger = 'calendar_reschedule_changes'
            AND source.source_operation_id = split_part(event.event_id, ':', 2)::uuid
          WHEN 'calendar_reschedule_reversed' THEN source.source_ledger = 'calendar_reschedule_reversals'
            AND source.source_operation_id = split_part(event.event_id, ':', 2)::uuid
          ELSE false END
      ORDER BY source.schedule_version DESC LIMIT 1
    ) AS link ON true
    LEFT JOIN public.product_schedule_operations AS operation
      ON operation.workspace_id = p_workspace_id AND operation.product_id = p_product_id
      AND operation.operation_id = link.operation_id
  ), bounded_legacy_feed AS MATERIALIZED (
    SELECT event.event_id, event.occurred_at, event.actor_id, event.event_type,
      event.item, event.justification, event.before_details, event.after_details,
      event.affected_items, event.operation_id, event.operation_type,
      event.reversal_of_operation_id, event.details
    FROM linked_specialized_feed AS event
    WHERE event.operation_id IS NULL AND (p_before_at IS NULL OR
      (event.occurred_at, event.event_id COLLATE "C") < (p_before_at, p_before_id COLLATE "C"))
    ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC
    LIMIT p_limit + 1
  ), bounded_specialized_feed AS (
    SELECT event.event_id, event.occurred_at, event.actor_id, event.event_type,
      event.item, event.justification, event.before_details, event.after_details,
      event.affected_items, event.operation_id, event.operation_type,
      event.reversal_of_operation_id, event.details
    FROM linked_specialized_feed AS event
    JOIN candidate_operations AS candidate ON candidate.workspace_id = p_workspace_id
      AND candidate.product_id = p_product_id AND candidate.operation_id = event.operation_id

    UNION ALL

    SELECT event.event_id, event.occurred_at, event.actor_id, event.event_type,
      event.item, event.justification, event.before_details, event.after_details,
      event.affected_items, event.operation_id, event.operation_type,
      event.reversal_of_operation_id, event.details
    FROM bounded_legacy_feed AS event
  ), combined_feed AS (
    SELECT event.event_id, event.occurred_at, event.actor_id, event.event_type,
      event.item, event.justification, event.before_details, event.after_details,
      event.affected_items, event.operation_id, event.operation_type,
      event.reversal_of_operation_id, event.details
    FROM bounded_specialized_feed AS event

    UNION ALL

    SELECT event.event_id, event.occurred_at, event.actor_id, event.event_type,
      event.item, event.justification, event.before_details, event.after_details,
      event.affected_items, event.operation_id, event.operation_type,
      event.reversal_of_operation_id, event.details
    FROM generic_operation_feed AS event
  ), logical_groups AS (
    SELECT CASE WHEN event.operation_id IS NULL THEN 'legacy:' || event.event_id
      ELSE 'operation:' || event.operation_id::text END AS group_key,
      event.operation_id,
      operation.occurred_at AS operation_occurred_at,
      operation.actor_id AS operation_actor_id,
      operation.operation_type AS header_operation_type,
      operation.justification AS header_justification,
      operation.reversal_of_operation_id AS header_reversal_id,
      count(*) AS row_count,
      count(*) FILTER (WHERE event.event_type = 'living_schedule_operation') AS generic_row_count,
      (array_agg(event.event_id ORDER BY event.event_id))[1] AS legacy_event_id,
      (array_agg(event.event_type ORDER BY event.event_id))[1] AS legacy_event_type,
      (array_agg(event.item ORDER BY event.event_id))[1] AS legacy_item,
      (array_agg(event.justification ORDER BY event.event_id))[1] AS legacy_justification,
      (array_agg(event.before_details ORDER BY event.event_id))[1] AS legacy_before,
      (array_agg(event.after_details ORDER BY event.event_id))[1] AS legacy_after,
      array_agg(DISTINCT event.event_type ORDER BY event.event_type) AS source_event_types
    FROM combined_feed AS event
    LEFT JOIN public.product_schedule_operations AS operation
      ON event.operation_id IS NOT NULL AND operation.workspace_id = p_workspace_id
      AND operation.product_id = p_product_id AND operation.operation_id = event.operation_id
    GROUP BY CASE WHEN event.operation_id IS NULL THEN 'legacy:' || event.event_id
      ELSE 'operation:' || event.operation_id::text END,
      event.operation_id, operation.occurred_at, operation.actor_id,
      operation.operation_type, operation.justification, operation.reversal_of_operation_id
  ), logical_details AS (
    SELECT grouped.group_key,
      COALESCE(jsonb_agg(detail.value ORDER BY event.event_id COLLATE "C", detail.ordinality), '[]'::jsonb) AS details
    FROM logical_groups AS grouped
    JOIN combined_feed AS event ON
      (grouped.operation_id IS NOT NULL AND event.operation_id = grouped.operation_id) OR
      (grouped.operation_id IS NULL AND 'legacy:' || event.event_id = grouped.group_key)
    CROSS JOIN LATERAL jsonb_array_elements(event.details) WITH ORDINALITY AS detail(value, ordinality)
    GROUP BY grouped.group_key
  ), logical_affected AS (
    SELECT grouped.group_key,
      COALESCE(jsonb_agg(DISTINCT item.value ORDER BY item.value), '[]'::jsonb) AS affected_items
    FROM logical_groups AS grouped
    JOIN combined_feed AS event ON
      (grouped.operation_id IS NOT NULL AND event.operation_id = grouped.operation_id) OR
      (grouped.operation_id IS NULL AND 'legacy:' || event.event_id = grouped.group_key)
    CROSS JOIN LATERAL jsonb_array_elements(event.affected_items) WITH ORDINALITY AS item(value, ordinality)
    GROUP BY grouped.group_key
  ), logical_feed AS (
    SELECT CASE WHEN grouped.operation_id IS NULL THEN grouped.legacy_event_id
      ELSE 'operation:' || grouped.operation_id::text END AS event_id,
      COALESCE(grouped.operation_occurred_at, event.occurred_at) AS occurred_at,
      COALESCE(grouped.operation_actor_id, event.actor_id) AS actor_id,
      CASE WHEN grouped.operation_id IS NULL THEN grouped.legacy_event_type
        WHEN grouped.generic_row_count > 0 OR cardinality(grouped.source_event_types) > 1
          THEN 'living_schedule_operation'
        ELSE grouped.legacy_event_type END AS event_type,
      CASE WHEN grouped.operation_id IS NULL OR grouped.row_count = 1
        THEN grouped.legacy_item ELSE NULL::jsonb END AS item,
      COALESCE(grouped.header_justification, grouped.legacy_justification) AS justification,
      CASE WHEN grouped.operation_id IS NULL OR grouped.row_count = 1
        THEN grouped.legacy_before ELSE NULL::jsonb END AS before_details,
      CASE WHEN grouped.operation_id IS NULL OR grouped.row_count = 1
        THEN grouped.legacy_after ELSE NULL::jsonb END AS after_details,
      COALESCE(affected.affected_items, '[]'::jsonb) AS affected_items,
      grouped.operation_id,
      grouped.header_operation_type AS operation_type,
      grouped.header_reversal_id AS reversal_of_operation_id,
      to_jsonb(grouped.source_event_types) AS source_event_types,
      details.details
    FROM logical_groups AS grouped
    JOIN logical_details AS details ON details.group_key = grouped.group_key
    LEFT JOIN logical_affected AS affected ON affected.group_key = grouped.group_key
    LEFT JOIN combined_feed AS event ON grouped.operation_id IS NULL
      AND event.event_id = grouped.legacy_event_id
  ), eligible AS MATERIALIZED ($feed$;
  v_old_event_source constant text := 'SELECT event.* FROM event_feed AS event';
  v_new_event_source constant text := 'SELECT event.* FROM logical_feed AS event';
  v_json_anchor constant text := '''eventType'', event.event_type, ''item'', event.item,';
  v_json_replacement constant text := '''eventType'', event.event_type, ''item'', event.item,
        ''operationId'', event.operation_id::text, ''operationType'', event.operation_type,
        ''reversalOfOperationId'', event.reversal_of_operation_id::text,
        ''sourceEventTypes'', event.source_event_types, ''details'', event.details,';
BEGIN
  IF v_definition IS NULL OR
     position('public.product_schedule_operation_source_events' IN v_definition) > 0 OR
     position('public.hierarchy_movement_events' IN v_definition) = 0 OR
     position('change.event_id::text' IN v_definition) = 0 OR
     position('ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC' IN v_definition) = 0 OR
     position('LIMIT p_limit + 1' IN v_definition) = 0 OR
     position(v_anchor IN v_definition) = 0 OR
     length(v_definition) - length(replace(v_definition, v_anchor, '')) <> length(v_anchor) OR
     position(v_old_event_source IN v_definition) = 0 OR
     length(v_definition) - length(replace(v_definition, v_old_event_source, '')) <> length(v_old_event_source) OR
     position(v_json_anchor IN v_definition) = 0 OR
     length(v_definition) - length(replace(v_definition, v_json_anchor, '')) <> length(v_json_anchor) THEN
    RAISE EXCEPTION 'Product history function differs from the reviewed 0022/0027/0028 definition.';
  END IF;

  v_definition := replace(v_definition, v_anchor, v_replacement);
  v_definition := replace(v_definition, v_old_event_source, v_new_event_source);
  v_definition := replace(v_definition, v_json_anchor, v_json_replacement);
  EXECUTE v_definition;
END;
$migration$;

CREATE FUNCTION public.link_product_schedule_history_provenance()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_workspace_id uuid;
  v_product_id uuid;
  v_source_id uuid;
  v_source_ledger text;
  v_operation_type text;
  v_operation record;
BEGIN
  IF TG_TABLE_NAME = 'products' THEN
    v_workspace_id := NEW.workspace_id;
    v_product_id := NEW.id;
    v_source_id := NEW.id;
    v_source_ledger := 'products';
    v_operation_type := NULL;
  ELSIF TG_TABLE_NAME = 'import_batches' THEN
    v_workspace_id := NEW.workspace_id;
    v_product_id := NEW.product_id;
    v_source_id := NEW.id;
    v_source_ledger := 'import_batches';
    v_operation_type := 'schedule_imported';
  ELSE
    RAISE EXCEPTION 'Unsupported product history provenance source.' USING ERRCODE = '23514';
  END IF;

  FOR v_operation IN
    SELECT operation.schedule_version, operation.operation_id
    FROM public.product_schedule_operations AS operation
    WHERE operation.workspace_id = v_workspace_id AND operation.product_id = v_product_id
      AND operation.transaction_id = pg_current_xact_id()
      AND (v_operation_type IS NULL OR operation.operation_type = v_operation_type)
      AND (v_source_ledger <> 'products' OR EXISTS (
        SELECT 1 FROM public.product_schedule_operation_events AS event
        WHERE event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
          AND event.schedule_version = operation.schedule_version
          AND event.entity_type = 'products' AND event.entity_id = v_source_id
          AND event.change_type = 'products_created'))
  LOOP
    INSERT INTO public.product_schedule_operation_source_events (
      workspace_id, product_id, schedule_version, operation_id, source_ledger,
      source_operation_id, source_event_id, link_kind
    ) VALUES (
      v_workspace_id, v_product_id, v_operation.schedule_version, v_operation.operation_id,
      v_source_ledger, v_source_id, v_source_id, 'audit_detail'
    ) ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.link_product_schedule_history_provenance() FROM PUBLIC, jlproject_worker;
GRANT EXECUTE ON FUNCTION public.link_product_schedule_history_provenance() TO neondb_owner;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind
)
SELECT operation.workspace_id, operation.product_id, operation.schedule_version,
  operation.operation_id, 'products', product.id, product.id, 'audit_detail'
FROM public.product_schedule_operations AS operation
JOIN public.product_schedule_operation_events AS event
  ON event.workspace_id = operation.workspace_id AND event.product_id = operation.product_id
  AND event.schedule_version = operation.schedule_version
JOIN public.products AS product ON product.workspace_id = operation.workspace_id
  AND product.id = operation.product_id AND product.id = event.entity_id
WHERE operation.operation_type = 'product_created'
  AND event.entity_type = 'products' AND event.change_type = 'products_created'
ON CONFLICT DO NOTHING;

INSERT INTO public.product_schedule_operation_source_events (
  workspace_id, product_id, schedule_version, operation_id, source_ledger,
  source_operation_id, source_event_id, link_kind
)
SELECT operation.workspace_id, operation.product_id, operation.schedule_version,
  operation.operation_id, 'import_batches', batch.id, batch.id, 'audit_detail'
FROM public.product_schedule_operations AS operation
JOIN public.import_batches AS batch ON batch.workspace_id = operation.workspace_id
  AND batch.product_id = operation.product_id
WHERE operation.operation_type = 'schedule_imported'
ON CONFLICT DO NOTHING;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner GRANTED BY neondb_owner;

CREATE CONSTRAINT TRIGGER products_z_history_source_link
  AFTER INSERT ON public.products DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_history_provenance();
CREATE CONSTRAINT TRIGGER import_batches_z_history_source_link
  AFTER INSERT ON public.import_batches DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.link_product_schedule_history_provenance();

DO $verification$
DECLARE
  v_function oid := 'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure;
BEGIN
  IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = v_function) <> 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_function AND prosecdef
       AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp']) OR
     NOT has_function_privilege('jlproject_worker', v_function, 'EXECUTE') OR
     EXISTS (SELECT 1 FROM pg_proc AS proc
       CROSS JOIN LATERAL aclexplode(COALESCE(proc.proacl,
         acldefault('f', proc.proowner))) AS privilege
       WHERE proc.oid = v_function AND privilege.grantee = 0
         AND privilege.privilege_type = 'EXECUTE') OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.link_product_schedule_history_provenance()'::regprocedure) <> 'jlproject_date_executor' OR
     NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid =
       'public.link_product_schedule_history_provenance()'::regprocedure AND prosecdef
       AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp']) OR
     has_function_privilege('jlproject_worker',
       'public.link_product_schedule_history_provenance()', 'EXECUTE') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operations', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.product_schedule_operation_source_events', 'SELECT') OR
     to_regclass('public.product_schedule_operations_history_time_idx') IS NULL OR
     (SELECT count(*) FROM pg_trigger WHERE tgname IN
       ('products_z_history_source_link', 'import_batches_z_history_source_link')
       AND tgenabled IN ('O', 'A') AND tgdeferrable AND tginitdeferred) <> 2 OR
     position('product_schedule_operation_source_events' IN pg_get_functiondef(v_function)) = 0 OR
     position('operation:' IN pg_get_functiondef(v_function)) = 0 THEN
    RAISE EXCEPTION 'Unified product history function ownership, security, or definition check failed.';
  END IF;
END;
$verification$;

COMMIT;
