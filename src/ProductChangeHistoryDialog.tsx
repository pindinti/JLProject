import { useCallback, useEffect, useRef, useState } from "react";
import { authenticatedFetch } from "./auth";
import { formatCivilDate } from "./civil-date";
import { ChangeHistoryDialog } from "./ChangeHistoryDialog";
import { messages } from "./locales/pt-BR";

type ProductHistoryEventType = "product_created" | "schedule_imported" | "activity_dates_changed" |
  "stage_dates_changed" | "business_target_date_changed" | "calendar_rescheduled" | "calendar_reschedule_reversed" |
  "schedule_hierarchy_deleted" | "hierarchy_moved" | "living_schedule_operation";
interface ProductHistoryItem {
  kind: string; id: string; name: string | null;
  hierarchy?: { scope?: string; discipline?: string | null; stage?: string | null };
}
interface ProductHistoryDetail {
  eventId: string; source: "specialized" | "living_schedule"; eventType: string;
  item: ProductHistoryItem | null; justification?: string | null;
  before?: Record<string, unknown> | null; after?: Record<string, unknown> | null;
  affectedItems?: Record<string, unknown>[]; entityType?: string; entityId?: string;
  changeType?: string; parentBefore?: Record<string, unknown>; parentAfter?: Record<string, unknown>;
}
interface ProductHistoryEvent {
  id: string; occurredAt: string; actorId: string; actorName: string | null; eventType: ProductHistoryEventType;
  item: ProductHistoryItem | null; justification: string | null;
  before: Record<string, unknown> | null; after: Record<string, unknown> | null;
  affectedItems: Record<string, unknown>[];
  operationId?: string; operationType?: string | null; reversalOfOperationId?: string | null;
  sourceEventTypes?: ProductHistoryEventType[]; details?: ProductHistoryDetail[];
}
interface ProductHistoryPage { events: ProductHistoryEvent[]; nextCursor: string | null }
interface ActivityChange {
  activityId: string; plannedStart?: string | null; plannedEnd?: string | null;
  workingDays?: number | null; calendarVersion?: number | null;
}

const pageSize = 25;
const historyTime = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo", day: "2-digit", month: "2-digit", year: "numeric",
  hour: "2-digit", minute: "2-digit"
});
const eventTypes: ProductHistoryEventType[] = ["product_created", "schedule_imported", "activity_dates_changed",
  "stage_dates_changed", "business_target_date_changed", "calendar_rescheduled", "calendar_reschedule_reversed",
  "schedule_hierarchy_deleted", "hierarchy_moved", "living_schedule_operation"];
const eventLabels: Record<ProductHistoryEventType, string> = {
  product_created: messages.productHistoryTypeProductCreated,
  schedule_imported: messages.productHistoryTypeImport,
  activity_dates_changed: messages.productHistoryTypeActivityDates,
  stage_dates_changed: messages.productHistoryTypeStageDates,
  business_target_date_changed: messages.productHistoryTypeTargetDate,
  calendar_rescheduled: messages.productHistoryTypeCalendarReschedule,
  calendar_reschedule_reversed: messages.productHistoryTypeCalendarReversal,
  schedule_hierarchy_deleted: messages.productHistoryTypeDeletion,
  hierarchy_moved: messages.productHistoryTypeMovement,
  living_schedule_operation: messages.productHistoryTypeOperation
};
const detailLabels: Record<string, string> = {
  plannedStart: messages.productHistoryStart,
  planned_start: messages.productHistoryStart,
  plannedEnd: messages.productHistoryEnd,
  planned_end: messages.productHistoryEnd,
  targetDate: messages.productHistoryTargetDate,
  target_date: messages.productHistoryTargetDate,
  sourceReferenceCount: messages.productHistorySourceReferences,
  affectedCount: messages.productHistoryAffectedCount,
  targetKind: messages.productHistoryItemType,
  workingDays: messages.productHistoryWorkingDays,
  calendarVersion: messages.productHistoryCalendarVersion,
  name: messages.productHistoryFieldName,
  description: messages.productHistoryFieldDescription,
  short_code: messages.productHistoryFieldShortCode,
  code: messages.productHistoryFieldCode,
  display_name: messages.productHistoryFieldName,
  display_order: messages.productHistoryFieldOrder,
  color: messages.productHistoryFieldColor,
  color_override: messages.productHistoryFieldColor,
  activity_type: messages.productHistoryFieldActivityType,
  notes: messages.productHistoryFieldNotes,
  active: messages.productHistoryFieldActive,
  is_active: messages.productHistoryFieldActive,
  discipline_id: messages.productHistoryFieldDiscipline,
  stage_id: messages.productHistoryFieldStage,
  activity_id: messages.productHistoryFieldActivity,
  originalOperationId: messages.productHistoryOriginalOperation,
  reversalOfOperationId: messages.productHistoryOriginalOperation
};

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

function isEvent(value: unknown): value is ProductHistoryEvent {
  const item = record(value);
  const detailItem = item && record(item.item);
  const hierarchy = detailItem?.hierarchy === undefined ? null : record(detailItem.hierarchy);
  const detailRows = item && Array.isArray(item.details) ? item.details : undefined;
  const validDetails = (detailRows: unknown[]): boolean => detailRows.every((entry) => {
    const detail = record(entry);
    const detailItem = detail?.item === null || detail?.item === undefined ? null : record(detail.item);
    return !!detail && typeof detail.eventId === "string" &&
      (detail.source === "specialized" || detail.source === "living_schedule") &&
      typeof detail.eventType === "string" &&
      (detail.justification === undefined || detail.justification === null || typeof detail.justification === "string") &&
      (detail.before === undefined || detail.before === null || !!record(detail.before)) &&
      (detail.after === undefined || detail.after === null || !!record(detail.after)) &&
      (detail.affectedItems === undefined || (Array.isArray(detail.affectedItems) &&
        detail.affectedItems.every((affected) => !!record(affected)))) &&
      (detail.item === undefined || detail.item === null || (!!detailItem &&
        typeof detailItem.kind === "string" && typeof detailItem.id === "string" &&
        (detailItem.name === null || detailItem.name === undefined || typeof detailItem.name === "string")));
  });
  return !!item && typeof item.id === "string" && typeof item.occurredAt === "string" &&
    !Number.isNaN(Date.parse(item.occurredAt)) &&
    typeof item.actorId === "string" &&
    (item.actorName === null || typeof item.actorName === "string") &&
    eventTypes.includes(item.eventType as ProductHistoryEventType) &&
    (item.item === null || (!!detailItem && typeof detailItem.kind === "string" &&
      typeof detailItem.id === "string" && (detailItem.name === null || typeof detailItem.name === "string") &&
      (detailItem.hierarchy === undefined || !!hierarchy))) &&
    (item.justification === null || typeof item.justification === "string") &&
    (item.before === null || !!record(item.before)) && (item.after === null || !!record(item.after)) &&
    Array.isArray(item.affectedItems) && item.affectedItems.every((entry) => !!record(entry)) &&
    (item.operationId === undefined || typeof item.operationId === "string") &&
    (item.operationType === undefined || item.operationType === null || typeof item.operationType === "string") &&
    (item.reversalOfOperationId === undefined || item.reversalOfOperationId === null ||
      typeof item.reversalOfOperationId === "string") &&
    (item.sourceEventTypes === undefined || (Array.isArray(item.sourceEventTypes) &&
      item.sourceEventTypes.every((type) => eventTypes.includes(type as ProductHistoryEventType)))) &&
    (detailRows === undefined || validDetails(detailRows));
}

function decodePage(value: unknown): ProductHistoryPage {
  const page = record(value);
  if (!page || !Array.isArray(page.events) || !page.events.every(isEvent) ||
      (page.nextCursor !== null && typeof page.nextCursor !== "string"))
    throw new Error("Invalid product change history page.");
  return { events: page.events, nextCursor: page.nextCursor as string | null };
}

function hierarchyLabel(item: ProductHistoryItem | Record<string, unknown> | null | undefined): string | null {
  const hierarchy = record(item?.hierarchy);
  if (hierarchy?.scope === "product_root") return messages.productHistoryProductRoot;
  const parts = [hierarchy?.discipline, hierarchy?.stage]
    .filter((value): value is string => typeof value === "string" && value.length > 0);
  return parts.length ? parts.join(" › ") : null;
}

function eventItemName(event: ProductHistoryEvent): string {
  if (event.item?.name) return event.item.name;
  if (event.eventType === "calendar_rescheduled") return messages.productHistoryBatchReschedule;
  if (event.eventType === "calendar_reschedule_reversed") return messages.productHistoryBatchReversal;
  if (event.eventType === "living_schedule_operation") return operationTypeLabel(event.operationType);
  return eventLabels[event.eventType];
}

const operationTypeLabels: Record<string, string> = {
  product_created: messages.productHistoryTypeProductCreated,
  product_metadata_updated: messages.productHistoryOperationProductMetadata,
  product_archived: messages.productHistoryOperationProductArchived,
  schedule_imported: messages.productHistoryTypeImport,
  activity_created_with_dates: messages.productHistoryOperationActivityCreated,
  stage_created_with_dates: messages.productHistoryOperationStageCreated,
  schedule_entity_created: messages.productHistoryOperationEntityCreated,
  schedule_metadata_updated: messages.productHistoryOperationMetadata,
  schedule_dates_changed: messages.productHistoryOperationDates,
  activity_dates_changed: messages.productHistoryTypeActivityDates,
  stage_dates_changed: messages.productHistoryTypeStageDates,
  activity_working_plan_changed: messages.productHistoryOperationActivityPlan,
  business_target_created: messages.productHistoryOperationTargetCreated,
  business_target_updated: messages.productHistoryOperationTargetUpdated,
  business_target_date_changed: messages.productHistoryTypeTargetDate,
  business_target_deleted: messages.productHistoryOperationTargetDeleted,
  schedule_deleted: messages.productHistoryTypeDeletion,
  hierarchy_moved: messages.productHistoryTypeMovement,
  calendar_rescheduled: messages.productHistoryTypeCalendarReschedule,
  calendar_reschedule_reversed: messages.productHistoryTypeCalendarReversal
};

function operationTypeLabel(operationType: string | null | undefined): string {
  return operationType ? operationTypeLabels[operationType] ?? messages.productHistoryTypeOperation
    : messages.productHistoryTypeOperation;
}

function affectsActivity(event: ProductHistoryEvent, activityId: string): boolean {
  return (event.item?.kind === "activity" && event.item.id === activityId) ||
    event.affectedItems.some((item) => item.id === activityId);
}

function displayScalar(value: unknown, key: string): string | null {
  if (typeof value === "string") {
    if (/^(plannedStart|plannedEnd|targetDate|planned_start|planned_end|target_date)$/.test(key) && /^\d{4}-\d{2}-\d{2}$/.test(value))
      return formatCivilDate(value);
    if (key === "targetKind" || key === "target_kind") return value === "activity" ? messages.productHistoryActivityKind :
      value === "stage" ? messages.productHistoryStageKind :
        value === "discipline" ? messages.productHistoryDisciplineKind :
          value === "business_target" ? messages.productHistoryTarget : value;
    return value;
  }
  if (typeof value === "boolean" && (key === "active" || key === "is_active"))
    return value ? messages.productHistoryActive : messages.productHistoryInactive;
  if (typeof value === "number" && Number.isFinite(value)) return value.toLocaleString("pt-BR");
  return null;
}

function detailRows(details: Record<string, unknown> | null): [string, string][] {
  if (!details) return [];
  return Object.entries(details).flatMap(([key, rawValue]) => {
    const label = detailLabels[key];
    if (!label) return [];
    const isCivilDate = /^(plannedStart|plannedEnd|targetDate|planned_start|planned_end|target_date)$/.test(key);
    const value = rawValue === null ? isCivilDate ? messages.noDate : messages.productHistoryNoValue
      : displayScalar(rawValue, key);
    return value === null ? [] : [[label, value] as [string, string]];
  });
}

function recordedParentLabel(value: Record<string, unknown> | undefined): string | null {
  if (!value) return null;
  const disciplineId = value.disciplineId;
  const stageId = value.stageId;
  const labels: string[] = [];
  if (typeof disciplineId === "string") labels.push(`${messages.productHistoryFieldDiscipline}: ${disciplineId}`);
  if (typeof stageId === "string") labels.push(`${messages.productHistoryFieldStage}: ${stageId}`);
  return labels.length ? labels.join(" · ") : null;
}

function GroupedOperationDetails({ details }: { details: ProductHistoryDetail[] }) {
  if (details.length === 0) return null;
  return <details className="product-history__details product-history__operation-details">
    <summary>{messages.productHistoryOperationDetails(details.length)}</summary>
    <ol className="product-history__operation-items">
      {details.map((detail) => {
        const detailName = detail.item?.name || (detail.item
          ? `${itemKindLabel(detail.item.kind)} · ${detail.item.id}` : messages.productHistoryChangeDetail);
        const beforeRows = detailRows(detail.before ?? null);
        const afterRows = detailRows(detail.after ?? null);
        const parentBefore = recordedParentLabel(detail.parentBefore);
        const parentAfter = recordedParentLabel(detail.parentAfter);
        const isCalendarEvent = detail.eventType === "calendar_rescheduled" ||
          detail.eventType === "calendar_reschedule_reversed";
        return <li key={`${detail.source}:${detail.eventId}`}>
          <strong>{detailName}</strong>
          {detail.source === "specialized" && detail.eventType === "hierarchy_moved" &&
            <span className="product-history__operation-kind">{messages.productHistoryTypeMovement}</span>}
          {(parentBefore || parentAfter) && <span className="product-history__hierarchy">
            {parentBefore && <span>{messages.productHistoryPreviousParent}: {parentBefore}</span>}
            {parentAfter && <span>{messages.productHistoryNewParent}: {parentAfter}</span>}
          </span>}
          {detail.source === "specialized" && detail.eventType === "hierarchy_moved" &&
            <MovementComparison event={{ before: detail.before ?? null, after: detail.after ?? null }} />}
          {detail.source === "specialized" && isCalendarEvent &&
            <ActivityDateComparison event={{ before: detail.before ?? null, after: detail.after ?? null,
              affectedItems: detail.affectedItems ?? [] }} />}
          {(beforeRows.length > 0 || afterRows.length > 0) && <div className="product-history__value-columns">
            {beforeRows.length > 0 && <section><h3>{messages.calendarBefore}</h3><dl>{beforeRows.map(([label, value]) =>
              <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl></section>}
            {afterRows.length > 0 && <section><h3>{messages.calendarAfter}</h3><dl>{afterRows.map(([label, value]) =>
              <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl></section>}
          </div>}
        </li>;
      })}
    </ol>
  </details>;
}

function itemKindLabel(kind: string): string {
  if (kind === "activity") return messages.productHistoryActivityKind;
  if (kind === "stage") return messages.productHistoryStageKind;
  if (kind === "discipline") return messages.productHistoryDisciplineKind;
  if (kind === "product") return messages.productHistoryProduct;
  if (kind === "business_target") return messages.productHistoryTarget;
  if (kind === "calendar_reschedule") return messages.productHistoryBatchReschedule;
  if (kind === "calendar_reschedule_reversal") return messages.productHistoryBatchReversal;
  return messages.productHistoryItem;
}

function movementParentLabel(details: Record<string, unknown> | null): string | null {
  const parent = record(details?.parent);
  if (!parent) return null;
  if (parent.scope === "product_root") return messages.productHistoryProductRoot;
  if (parent.scope === "product") return messages.productHistoryProduct;
  const parts = [parent.discipline, parent.stage]
    .filter((value): value is string => typeof value === "string" && value.length > 0);
  return parts.length ? parts.join(" › ") : messages.productHistoryLocationUnavailable;
}

function movementPosition(details: Record<string, unknown> | null): string | null {
  const position = details?.position;
  return typeof position === "number" && Number.isSafeInteger(position) && position > 0
    ? position.toLocaleString("pt-BR") : null;
}

function movementEventLabel(event: ProductHistoryEvent): string {
  if (event.eventType !== "hierarchy_moved") return event.eventType === "living_schedule_operation"
    ? operationTypeLabel(event.operationType) : eventLabels[event.eventType];
  if (event.item?.kind === "activity") return messages.productHistoryActivityMoved;
  if (event.item?.kind === "stage") return messages.productHistoryStageMoved;
  if (event.item?.kind === "discipline") return messages.productHistoryDisciplineMoved;
  return eventLabels.hierarchy_moved;
}

function MovementComparison({ event }: { event: Pick<ProductHistoryEvent, "before" | "after"> }) {
  const beforeLocation = movementParentLabel(event.before);
  const afterLocation = movementParentLabel(event.after);
  const beforePosition = movementPosition(event.before);
  const afterPosition = movementPosition(event.after);
  return <div className="product-history__value-columns product-history__movement-comparison">
    <section><h3>{messages.calendarBefore}</h3><dl>
      {beforeLocation && <div><dt>{messages.productHistoryPreviousParent}</dt><dd>{beforeLocation}</dd></div>}
      {beforePosition && <div><dt>{messages.productHistoryPreviousPosition}</dt><dd>{beforePosition}</dd></div>}
    </dl></section>
    <section><h3>{messages.calendarAfter}</h3><dl>
      {afterLocation && <div><dt>{messages.productHistoryNewParent}</dt><dd>{afterLocation}</dd></div>}
      {afterPosition && <div><dt>{messages.productHistoryNewPosition}</dt><dd>{afterPosition}</dd></div>}
    </dl></section>
  </div>;
}

function activityChanges(value: unknown): ActivityChange[] {
  const details = record(value);
  if (!Array.isArray(details?.activities)) return [];
  return details.activities.flatMap((entry) => {
    const item = record(entry);
    return item && typeof item.activityId === "string" ? [item as unknown as ActivityChange] : [];
  });
}

function ActivityDateComparison({ event }: { event: {
  before: Record<string, unknown> | null; after: Record<string, unknown> | null;
  affectedItems: Record<string, unknown>[];
} }) {
  const before = activityChanges(event.before);
  const after = activityChanges(event.after);
  if (before.length === 0 && after.length === 0) return null;
  const beforeById = new Map(before.map((item) => [item.activityId, item]));
  const afterById = new Map(after.map((item) => [item.activityId, item]));
  const affected = new Map(event.affectedItems.flatMap((item) =>
    typeof item.id === "string" ? [[item.id, item] as const] : []));
  const ids = [...new Set([...beforeById.keys(), ...afterById.keys()])];
  return <ul className="product-history__activity-changes">
    {ids.map((id) => {
      const item = affected.get(id);
      const previous = beforeById.get(id);
      const next = afterById.get(id);
      const dateRange = (change: ActivityChange | undefined) => change
        ? messages.dateRange(formatCivilDate(change.plannedStart ?? null), formatCivilDate(change.plannedEnd ?? null))
        : messages.noDate;
      return <li key={id}>
        <strong>{typeof item?.name === "string" ? item.name : messages.productHistoryNameUnavailable}</strong>
        {hierarchyLabel(item) && <span className="product-history__hierarchy">{hierarchyLabel(item)}</span>}
        <div className="product-history__date-comparison">
          <span><small>{messages.calendarBefore}</small>{dateRange(previous)}</span>
          <span><small>{messages.calendarAfter}</small>{dateRange(next)}</span>
        </div>
        {(previous?.workingDays !== undefined || next?.workingDays !== undefined) && <small>
          {messages.productHistoryWorkingDays}: {displayScalar(next?.workingDays ?? previous?.workingDays, "workingDays") ?? messages.noDate}
        </small>}
        {(previous?.calendarVersion !== undefined || next?.calendarVersion !== undefined) && <small>
          {messages.productHistoryCalendarVersion}: {displayScalar(next?.calendarVersion ?? previous?.calendarVersion, "calendarVersion") ?? messages.noDate}
        </small>}
      </li>;
    })}
  </ul>;
}

function StageDateComparison({ event }: { event: ProductHistoryEvent }) {
  const dateValue = (value: Record<string, unknown> | null, key: "plannedStart" | "plannedEnd") => {
    const date = value?.[key];
    return typeof date === "string" ? displayScalar(date, key) ?? messages.noDate : messages.noDate;
  };
  return <div className="product-history__value-columns product-history__stage-date-comparison">
    <section><h3>{messages.calendarBefore}</h3><dl>
      <div><dt>{messages.productHistoryStart}</dt><dd>{dateValue(event.before, "plannedStart")}</dd></div>
      <div><dt>{messages.productHistoryEnd}</dt><dd>{dateValue(event.before, "plannedEnd")}</dd></div>
    </dl></section>
    <section><h3>{messages.calendarAfter}</h3><dl>
      <div><dt>{messages.productHistoryStart}</dt><dd>{dateValue(event.after, "plannedStart")}</dd></div>
      <div><dt>{messages.productHistoryEnd}</dt><dd>{dateValue(event.after, "plannedEnd")}</dd></div>
    </dl></section>
  </div>;
}

function HistoryEventCard({ event }: { event: ProductHistoryEvent }) {
  const itemHierarchy = hierarchyLabel(event.item);
  const affected = event.affectedItems.filter((item) => typeof item.name === "string");
  const beforeRows = detailRows(event.before);
  const afterRows = detailRows(event.after);
  const hasMovement = event.eventType === "hierarchy_moved";
  const hasStageDates = event.eventType === "stage_dates_changed";
  const hasActivityDates = activityChanges(event.before).length > 0 || activityChanges(event.after).length > 0;
  const genericDetails = beforeRows.length > 0 || afterRows.length > 0;
  return <li className="product-history__event">
    <header className="product-history__event-header">
      <div className="product-history__event-main">
        <strong className="product-history__item-name">{eventItemName(event)}</strong>
        <time dateTime={event.occurredAt}>{historyTime.format(new Date(event.occurredAt))}</time>
        <span>{event.actorName ?? messages.stageDateActor(event.actorId)}</span>
      </div>
        <span className="product-history__event-type">{movementEventLabel(event)}</span>
    </header>
    {itemHierarchy && <p className="product-history__hierarchy">{itemHierarchy}</p>}
    {event.justification && <p className="product-history__justification">
      <strong>{messages.productHistoryJustification}:</strong> {event.justification}
    </p>}
    {event.reversalOfOperationId && <p className="product-history__operation-context">
      <strong>{messages.productHistoryOriginalOperation}:</strong> {event.reversalOfOperationId}
    </p>}
    {event.operationId && event.details &&
      (event.eventType === "living_schedule_operation" || event.details.length > 1) &&
      <GroupedOperationDetails details={event.details} />}
    {affected.length > 0 && <details className="product-history__details">
      <summary>{messages.productHistoryAffected(affected.length)}</summary>
      <ul className="product-history__affected-items">{affected.map((item, index) => <li key={`${String(item.id)}:${index}`}>
        <strong>{String(item.name)}</strong>
        {hierarchyLabel(item) && <span className="product-history__hierarchy">{hierarchyLabel(item)}</span>}
      </li>)}</ul>
    </details>}
    {(genericDetails || hasActivityDates || hasMovement || hasStageDates) && <details className="product-history__details">
      <summary>{messages.productHistoryBeforeAfter}</summary>
      {hasMovement ? <MovementComparison event={event} /> : hasActivityDates ? <ActivityDateComparison event={event} /> : hasStageDates
        ? <StageDateComparison event={event} /> : <div className="product-history__value-columns">
        {beforeRows.length > 0 && <section><h3>{messages.calendarBefore}</h3><dl>{beforeRows.map(([label, value]) => <div key={label}>
          <dt>{label}</dt><dd>{value}</dd></div>)}</dl></section>}
        {afterRows.length > 0 && <section><h3>{messages.calendarAfter}</h3><dl>{afterRows.map(([label, value]) => <div key={label}>
          <dt>{label}</dt><dd>{value}</dd></div>)}</dl></section>}
      </div>}
    </details>}
  </li>;
}

export function ProductChangeHistoryDialog({ base, onAccessLost, onClose, activity }: {
  base: string; onAccessLost: () => void; onClose: () => void;
  activity?: { id: string; name: string };
}) {
  const [events, setEvents] = useState<ProductHistoryEvent[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [filter, setFilter] = useState<ProductHistoryEventType | "all">("all");
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState(false);
  const [retryCursor, setRetryCursor] = useState<string | null>(null);
  const requestSequence = useRef(0);

  const loadPage = useCallback(async (cursor: string | null, append: boolean) => {
    const requestId = ++requestSequence.current;
    setError(false);
    setRetryCursor(null);
    if (append) setLoadingMore(true); else setLoading(true);
    try {
      const params = new URLSearchParams({ limit: String(pageSize) });
      if (cursor) params.set("cursor", cursor);
      const response = await authenticatedFetch(`${base}/change-history?${params}`, { cache: "no-store" });
      if (requestId !== requestSequence.current) return;
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Product change history lookup failed.");
      const page = decodePage(await response.json());
      if (requestId !== requestSequence.current) return;
      setEvents((previous) => {
        const combined = append ? [...previous, ...page.events] : page.events;
        const seen = new Set<string>();
        return combined.filter((event) => {
          if (seen.has(event.id)) return false;
          seen.add(event.id);
          return true;
        });
      });
      setNextCursor(page.nextCursor);
    } catch {
      if (requestId === requestSequence.current) { setError(true); setRetryCursor(cursor); }
    } finally {
      if (requestId === requestSequence.current) { setLoading(false); setLoadingMore(false); }
    }
  }, [base, onAccessLost]);

  useEffect(() => {
    queueMicrotask(() => void loadPage(null, false));
    return () => { requestSequence.current += 1; };
  }, [loadPage]);

  const visibleEvents = events.filter((event) => (filter === "all" || event.eventType === filter ||
    event.sourceEventTypes?.includes(filter)) &&
    (!activity || affectsActivity(event, activity.id)));
  const title = activity ? messages.productActivityHistory(activity.name) : messages.productHistoryTitle;
  const noEvents = events.length === 0 && nextCursor === null;
  const noMatches = visibleEvents.length === 0 && (events.length > 0 || nextCursor !== null);
  const noMatchMessage = nextCursor ? messages.productHistoryMoreToSearch
    : activity ? (filter === "all" ? messages.productHistoryActivityEmpty : messages.productHistoryActivityFilterEmpty)
      : messages.productHistoryFilterEmpty;

  return <ChangeHistoryDialog title={title} className="product-history-dialog" closeLabel={messages.productHistoryClose}
    onClose={onClose} footer={<div className="product-history__footer">
      <span>{messages.productHistoryAuditDisclaimer}</span>
      <div>
        {nextCursor && !error && <button type="button" disabled={loading || loadingMore}
          onClick={() => void loadPage(nextCursor, true)}>
          {loadingMore ? messages.productHistoryLoadingMore : messages.productHistoryMore}</button>}
        <button type="button" onClick={onClose}>{messages.closeHistory}</button>
      </div>
    </div>}>
    <p className="product-history__coverage" role="note">{messages.productHistoryCoverage}</p>
    {activity && <p className="product-history__scope">{messages.productHistoryFilteredBy(activity.name)}</p>}
    <label className="product-history__filter" htmlFor="product-history-filter">{messages.productHistoryFilter}</label>
    <select id="product-history-filter" value={filter}
      onChange={(event) => setFilter(event.target.value as ProductHistoryEventType | "all")}>
      <option value="all">{messages.productHistoryAllTypes}</option>
      {eventTypes.map((type) => <option key={type} value={type}>{eventLabels[type]}</option>)}
    </select>
    {loading && events.length === 0 && <p role="status">{messages.productHistoryLoading}</p>}
    {error && <div role="alert"><p>{messages.productHistoryError}</p>
      <button type="button" onClick={() => void loadPage(retryCursor, events.length > 0)}>{messages.retry}</button>
    </div>}
    {!loading && !error && noEvents && <p>{messages.productHistoryEmpty}</p>}
    {!loading && !error && noMatches && <p>{noMatchMessage}</p>}
    {visibleEvents.length > 0 && <ol className="product-history__list">
      {visibleEvents.map((event) => <HistoryEventCard event={event} key={event.id} />)}
    </ol>}
    {loadingMore && <p role="status">{messages.productHistoryLoadingMore}</p>}
  </ChangeHistoryDialog>;
}
