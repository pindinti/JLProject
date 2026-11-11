BEGIN;

DO $$
BEGIN
  IF current_user <> 'neondb_owner' OR current_database() <> 'neondb' OR
     to_regprocedure('public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)') IS NOT NULL OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_date_executor' AND NOT rolcanlogin) OR
     NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'jlproject_worker' AND rolcanlogin) OR
     has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.workspace_memberships', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.products', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.stage_activities', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.business_targets', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.activity_date_changes', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.business_target_date_changes', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.calendar_reschedule_changes', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.calendar_reschedule_reversals', 'SELECT') OR
     NOT has_table_privilege('jlproject_date_executor', 'public.schedule_deletion_events', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'workspace_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'product_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'workspace_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'product_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'discipline_id', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'SELECT') THEN
    RAISE EXCEPTION 'Product change history prerequisites or privilege boundaries are not satisfied.';
  END IF;
END;
$$;

-- The definer needs only retained import provenance counts and labels for deleted hierarchy rows.
GRANT SELECT (name) ON public.product_disciplines TO jlproject_date_executor;
GRANT SELECT (display_name) ON public.discipline_stages TO jlproject_date_executor;
GRANT SELECT (id, workspace_id, product_id, created_by, created_at)
  ON public.import_batches TO jlproject_date_executor;
GRANT SELECT (import_batch_id) ON public.import_source_rows TO jlproject_date_executor;

GRANT CREATE ON SCHEMA public TO jlproject_date_executor;
GRANT jlproject_date_executor TO neondb_owner;
SET ROLE jlproject_date_executor;

CREATE FUNCTION public.list_product_change_history(
  p_workspace_id uuid,
  p_product_id uuid,
  p_actor_id uuid,
  p_limit integer,
  p_before_at timestamptz,
  p_before_id text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_events jsonb;
  v_has_more boolean;
  v_next_cursor jsonb;
BEGIN
  IF p_workspace_id IS NULL OR p_product_id IS NULL OR p_actor_id IS NULL OR
     p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR
     ((p_before_at IS NULL) <> (p_before_id IS NULL)) OR
     (p_before_id IS NOT NULL AND p_before_id !~
       '^[a-z][a-z0-9_-]*:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
    RETURN jsonb_build_object('status', 'invalid');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.workspace_memberships AS membership
    WHERE membership.workspace_id = p_workspace_id AND
      membership.auth_user_id = p_actor_id AND membership.active = true
  ) THEN
    RETURN jsonb_build_object('status', 'forbidden');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.products AS product
    WHERE product.workspace_id = p_workspace_id AND product.id = p_product_id
  ) THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  WITH deletion_items AS (
    SELECT event.operation_id, 1 AS kind_order, item.id,
      jsonb_build_object('kind', 'discipline', 'id', item.id::text, 'name', discipline.name,
        'versionBefore', item.version, 'hierarchy', jsonb_build_object('discipline', discipline.name)) AS value
    FROM public.schedule_deletion_events AS event
    CROSS JOIN LATERAL jsonb_to_recordset(event.affected_items)
      AS item(kind text, id uuid, version bigint)
    JOIN public.product_disciplines AS discipline ON item.kind = 'discipline'
      AND discipline.id = item.id AND discipline.workspace_id = event.workspace_id
      AND discipline.product_id = event.product_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id

    UNION ALL

    SELECT event.operation_id, 2, item.id,
      jsonb_build_object('kind', 'stage', 'id', item.id::text, 'name', stage.display_name,
        'versionBefore', item.version,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
    FROM public.schedule_deletion_events AS event
    CROSS JOIN LATERAL jsonb_to_recordset(event.affected_items)
      AS item(kind text, id uuid, version bigint)
    JOIN public.discipline_stages AS stage ON item.kind = 'stage' AND stage.id = item.id
      AND stage.workspace_id = event.workspace_id AND stage.product_id = event.product_id
    JOIN public.product_disciplines AS discipline ON discipline.id = stage.discipline_id
      AND discipline.workspace_id = stage.workspace_id AND discipline.product_id = stage.product_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id

    UNION ALL

    SELECT event.operation_id, 3, item.id,
      jsonb_build_object('kind', 'activity', 'id', item.id::text, 'name', activity.name,
        'versionBefore', item.version,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
    FROM public.schedule_deletion_events AS event
    CROSS JOIN LATERAL jsonb_to_recordset(event.affected_items)
      AS item(kind text, id uuid, version bigint)
    JOIN public.stage_activities AS activity ON item.kind = 'activity' AND activity.id = item.id
      AND activity.workspace_id = event.workspace_id AND activity.product_id = event.product_id
    JOIN public.discipline_stages AS stage ON stage.id = activity.stage_id
      AND stage.workspace_id = activity.workspace_id AND stage.product_id = activity.product_id
    JOIN public.product_disciplines AS discipline ON discipline.id = activity.discipline_id
      AND discipline.workspace_id = activity.workspace_id AND discipline.product_id = activity.product_id
    WHERE event.workspace_id = p_workspace_id AND event.product_id = p_product_id
  ), deletion_item_lists AS (
    SELECT operation_id, jsonb_agg(value ORDER BY kind_order, id) AS items
    FROM deletion_items GROUP BY operation_id
  ),
  event_feed AS (
    SELECT 'product:' || product.id::text AS event_id, product.created_at AS occurred_at,
      product.created_by AS actor_id, 'product_created'::text AS event_type,
      jsonb_build_object('kind', 'product', 'id', product.id::text, 'name', product.name) AS item,
      NULL::text AS justification, NULL::jsonb AS before_details, NULL::jsonb AS after_details,
      '[]'::jsonb AS affected_items
    FROM public.products AS product
    WHERE product.workspace_id = p_workspace_id AND product.id = p_product_id

    UNION ALL

    SELECT 'import:' || batch.id::text, batch.created_at, batch.created_by, 'schedule_imported',
      jsonb_build_object('kind', 'product', 'id', product.id::text, 'name', product.name),
      NULL::text, NULL::jsonb,
      jsonb_build_object('sourceReferenceCount', (
        SELECT count(source.import_batch_id) FROM public.import_source_rows AS source
        WHERE source.import_batch_id = batch.id)),
      '[]'::jsonb
    FROM public.import_batches AS batch
    JOIN public.products AS product ON product.workspace_id = batch.workspace_id
      AND product.id = batch.product_id
    WHERE batch.workspace_id = p_workspace_id AND batch.product_id = p_product_id

    UNION ALL

    SELECT 'activity-date:' || change.operation_id::text, change.changed_at, change.actor_id,
      'activity_dates_changed',
      jsonb_build_object('kind', 'activity', 'id', activity.id::text, 'name', activity.name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name)),
      change.reason,
      jsonb_build_object('plannedStart', to_char(change.previous_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(change.previous_end, 'YYYY-MM-DD')),
      jsonb_build_object('plannedStart', to_char(change.new_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(change.new_end, 'YYYY-MM-DD')),
      '[]'::jsonb
    FROM public.activity_date_changes AS change
    JOIN public.stage_activities AS activity ON activity.workspace_id = change.workspace_id
      AND activity.product_id = change.product_id AND activity.id = change.activity_id
    JOIN public.discipline_stages AS stage ON stage.workspace_id = change.workspace_id
      AND stage.product_id = change.product_id AND stage.id = change.stage_id
    JOIN public.product_disciplines AS discipline ON discipline.workspace_id = change.workspace_id
      AND discipline.product_id = change.product_id AND discipline.id = change.discipline_id
    WHERE change.workspace_id = p_workspace_id AND change.product_id = p_product_id
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_changes AS reschedule
        WHERE reschedule.date_operation_id = change.operation_id)
      AND NOT EXISTS (SELECT 1 FROM public.calendar_reschedule_reversals AS reversal
        WHERE reversal.reversal_date_operation_id = change.operation_id)

    UNION ALL

    SELECT 'target-date:' || change.operation_id::text, change.changed_at, change.actor_id,
      'business_target_date_changed',
      jsonb_build_object('kind', 'business_target', 'id', target.id::text, 'name', target.name),
      change.reason,
      jsonb_build_object('targetDate', to_char(change.previous_date, 'YYYY-MM-DD')),
      jsonb_build_object('targetDate', to_char(change.new_date, 'YYYY-MM-DD')),
      '[]'::jsonb
    FROM public.business_target_date_changes AS change
    JOIN public.business_targets AS target ON target.workspace_id = change.workspace_id
      AND target.product_id = change.product_id AND target.id = change.target_id
    WHERE change.workspace_id = p_workspace_id AND change.product_id = p_product_id

    UNION ALL

    SELECT 'calendar-reschedule:' || reschedule.batch_operation_id::text,
      min(reschedule.changed_at), reschedule.actor_id, 'calendar_rescheduled',
      jsonb_build_object('kind', 'calendar_reschedule', 'id', reschedule.batch_operation_id::text,
        'name', NULL), reschedule.reason,
      jsonb_build_object('activities', jsonb_agg(jsonb_build_object(
        'activityId', reschedule.activity_id::text,
        'plannedStart', to_char(reschedule.previous_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(reschedule.previous_end, 'YYYY-MM-DD'),
        'workingDays', reschedule.working_day_duration,
        'calendarVersion', reschedule.previous_calendar_version)
        ORDER BY activity.name, reschedule.activity_id)),
      jsonb_build_object('activities', jsonb_agg(jsonb_build_object(
        'activityId', reschedule.activity_id::text,
        'plannedStart', to_char(reschedule.new_start, 'YYYY-MM-DD'),
        'plannedEnd', to_char(reschedule.new_end, 'YYYY-MM-DD'),
        'workingDays', reschedule.working_day_duration,
        'calendarVersion', reschedule.new_calendar_version)
        ORDER BY activity.name, reschedule.activity_id)),
      jsonb_agg(jsonb_build_object('kind', 'activity', 'id', reschedule.activity_id::text,
        'name', activity.name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
        ORDER BY activity.name, reschedule.activity_id)
    FROM public.calendar_reschedule_changes AS reschedule
    JOIN public.stage_activities AS activity ON activity.workspace_id = reschedule.workspace_id
      AND activity.product_id = reschedule.product_id AND activity.id = reschedule.activity_id
    JOIN public.discipline_stages AS stage ON stage.workspace_id = activity.workspace_id
      AND stage.product_id = activity.product_id AND stage.id = activity.stage_id
    JOIN public.product_disciplines AS discipline ON discipline.workspace_id = activity.workspace_id
      AND discipline.product_id = activity.product_id AND discipline.id = activity.discipline_id
    WHERE reschedule.workspace_id = p_workspace_id AND reschedule.product_id = p_product_id
    GROUP BY reschedule.batch_operation_id, reschedule.actor_id, reschedule.reason

    UNION ALL

    SELECT 'calendar-reversal:' || reversal.reversal_batch_operation_id::text,
      min(reversal.reversed_at), reversal.actor_id, 'calendar_reschedule_reversed',
      jsonb_build_object('kind', 'calendar_reschedule_reversal',
        'id', reversal.reversal_batch_operation_id::text, 'name', NULL), reversal.reason,
      jsonb_build_object('originalOperationId', reversal.original_batch_operation_id::text,
        'activities', jsonb_agg(jsonb_build_object(
          'activityId', reversal.activity_id::text,
          'plannedStart', to_char(reversal.before_start, 'YYYY-MM-DD'),
          'plannedEnd', to_char(reversal.before_end, 'YYYY-MM-DD'),
          'calendarVersion', reversal.before_calendar_version)
          ORDER BY activity.name, reversal.activity_id)),
      jsonb_build_object('originalOperationId', reversal.original_batch_operation_id::text,
        'activities', jsonb_agg(jsonb_build_object(
          'activityId', reversal.activity_id::text,
          'plannedStart', to_char(reversal.restored_start, 'YYYY-MM-DD'),
          'plannedEnd', to_char(reversal.restored_end, 'YYYY-MM-DD'),
          'calendarVersion', reversal.restored_calendar_version)
          ORDER BY activity.name, reversal.activity_id)),
      jsonb_agg(jsonb_build_object('kind', 'activity', 'id', reversal.activity_id::text,
        'name', activity.name,
        'hierarchy', jsonb_build_object('discipline', discipline.name, 'stage', stage.display_name))
        ORDER BY activity.name, reversal.activity_id)
    FROM public.calendar_reschedule_reversals AS reversal
    JOIN public.stage_activities AS activity ON activity.workspace_id = reversal.workspace_id
      AND activity.product_id = reversal.product_id AND activity.id = reversal.activity_id
    JOIN public.discipline_stages AS stage ON stage.workspace_id = activity.workspace_id
      AND stage.product_id = activity.product_id AND stage.id = activity.stage_id
    JOIN public.product_disciplines AS discipline ON discipline.workspace_id = activity.workspace_id
      AND discipline.product_id = activity.product_id AND discipline.id = activity.discipline_id
    WHERE reversal.workspace_id = p_workspace_id AND reversal.product_id = p_product_id
    GROUP BY reversal.reversal_batch_operation_id, reversal.original_batch_operation_id,
      reversal.actor_id, reversal.reason

    UNION ALL

    SELECT 'deletion:' || deletion.operation_id::text, deletion.changed_at, deletion.actor_id,
      'schedule_hierarchy_deleted',
      CASE deletion.target_kind
        WHEN 'discipline' THEN (SELECT jsonb_build_object('kind', 'discipline', 'id', d.id::text,
          'name', d.name, 'hierarchy', jsonb_build_object('discipline', d.name))
          FROM public.product_disciplines AS d WHERE d.workspace_id = deletion.workspace_id
            AND d.product_id = deletion.product_id AND d.id = deletion.target_id)
        WHEN 'stage' THEN (SELECT jsonb_build_object('kind', 'stage', 'id', s.id::text,
          'name', s.display_name, 'hierarchy', jsonb_build_object('discipline', d.name, 'stage', s.display_name))
          FROM public.discipline_stages AS s JOIN public.product_disciplines AS d
            ON d.workspace_id = s.workspace_id AND d.product_id = s.product_id AND d.id = s.discipline_id
          WHERE s.workspace_id = deletion.workspace_id AND s.product_id = deletion.product_id
            AND s.id = deletion.target_id)
        ELSE (SELECT jsonb_build_object('kind', 'activity', 'id', a.id::text,
          'name', a.name, 'hierarchy', jsonb_build_object('discipline', d.name, 'stage', s.display_name))
          FROM public.stage_activities AS a JOIN public.discipline_stages AS s
            ON s.workspace_id = a.workspace_id AND s.product_id = a.product_id AND s.id = a.stage_id
          JOIN public.product_disciplines AS d ON d.workspace_id = a.workspace_id
            AND d.product_id = a.product_id AND d.id = a.discipline_id
          WHERE a.workspace_id = deletion.workspace_id AND a.product_id = deletion.product_id
            AND a.id = deletion.target_id)
      END,
      deletion.reason, NULL::jsonb,
      jsonb_build_object('targetKind', deletion.target_kind, 'targetId', deletion.target_id::text,
        'affectedCount', jsonb_array_length(deletion.affected_items)),
      COALESCE(deletion_items.items, '[]'::jsonb)
    FROM public.schedule_deletion_events AS deletion
    LEFT JOIN deletion_item_lists AS deletion_items ON deletion_items.operation_id = deletion.operation_id
    WHERE deletion.workspace_id = p_workspace_id AND deletion.product_id = p_product_id
  ), eligible AS MATERIALIZED (
    SELECT event.* FROM event_feed AS event
    WHERE p_before_at IS NULL OR
      (event.occurred_at, event.event_id COLLATE "C") < (p_before_at, p_before_id COLLATE "C")
    ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC
    LIMIT p_limit + 1
  ), page AS MATERIALIZED (
    SELECT * FROM eligible ORDER BY occurred_at DESC, event_id COLLATE "C" DESC LIMIT p_limit
  ), page_data AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', event.event_id, 'occurredAt', to_char(event.occurred_at AT TIME ZONE 'UTC',
          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'actorId', event.actor_id::text, 'actorName', NULL, 'eventType', event.event_type, 'item', event.item,
        'justification', event.justification, 'before', event.before_details,
        'after', event.after_details, 'affectedItems', event.affected_items)
        ORDER BY event.occurred_at DESC, event.event_id COLLATE "C" DESC), '[]'::jsonb) AS events
    FROM page AS event
  ), pagination AS (
    SELECT EXISTS (SELECT 1 FROM eligible OFFSET p_limit) AS has_more
  ), cursor_data AS (
    SELECT jsonb_build_object('occurredAt', to_char(last_event.occurred_at AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), 'eventId', last_event.event_id) AS next_cursor
    FROM (SELECT occurred_at, event_id FROM page
      ORDER BY occurred_at ASC, event_id COLLATE "C" ASC LIMIT 1) AS last_event
  )
  SELECT page_data.events, pagination.has_more,
    CASE WHEN pagination.has_more THEN cursor_data.next_cursor ELSE NULL END
  INTO v_events, v_has_more, v_next_cursor
  FROM page_data CROSS JOIN pagination LEFT JOIN cursor_data ON true;

  RETURN jsonb_build_object('status', 'ok', 'events', v_events, 'nextCursor', v_next_cursor);
END;
$$;

REVOKE ALL ON FUNCTION public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)
  TO jlproject_worker;

RESET ROLE;
REVOKE CREATE ON SCHEMA public FROM jlproject_date_executor;
REVOKE jlproject_date_executor FROM neondb_owner;

DO $$
BEGIN
  IF has_schema_privilege('jlproject_date_executor', 'public', 'CREATE') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'usage') OR
     pg_has_role('neondb_owner', 'jlproject_date_executor', 'set') OR
     pg_has_role('jlproject_worker', 'jlproject_date_executor', 'member') OR
     NOT has_function_privilege('jlproject_worker',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     has_function_privilege('public',
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)', 'EXECUTE') OR
     (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid =
       'public.list_product_change_history(uuid,uuid,uuid,integer,timestamptz,text)'::regprocedure)
       <> 'jlproject_date_executor' OR
     NOT has_column_privilege('jlproject_date_executor', 'public.product_disciplines', 'name', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.discipline_stages', 'display_name', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'workspace_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'product_id', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'created_by', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_batches', 'created_at', 'SELECT') OR
     NOT has_column_privilege('jlproject_date_executor', 'public.import_source_rows', 'import_batch_id', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'SELECT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_changes', 'DELETE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.calendar_reschedule_reversals', 'DELETE') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'INSERT') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.schedule_deletion_events', 'DELETE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'UPDATE') OR
     has_table_privilege('jlproject_worker', 'public.initial_schedule_revisions', 'DELETE') THEN
    RAISE EXCEPTION 'Product change history privileges are not restricted.';
  END IF;
END;
$$;

COMMIT;
