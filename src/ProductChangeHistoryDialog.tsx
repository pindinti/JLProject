import { useCallback, useEffect, useRef, useState } from "react";
import { authenticatedFetch } from "./auth";
import { formatCivilDate } from "./civil-date";
import { ChangeHistoryDialog } from "./ChangeHistoryDialog";
import { messages } from "./locales/pt-BR";

type ProductHistoryEventType = "product_created" | "schedule_imported" | "activity_dates_changed" |
  "business_target_date_changed" | "calendar_rescheduled" | "calendar_reschedule_reversed" |
  "schedule_hierarchy_deleted" | "hierarchy_moved";
interface ProductHistoryItem {
  kind: string; id: string; name: string | null;
  hierarchy?: { scope?: string; discipline?: string | null; stage?: string | null };
}
interface ProductHistoryEvent {
  id: string; occurredAt: string; actorName: string | null; eventType: ProductHistoryEventType;
  item: ProductHistoryItem | null; justification: string | null;
  before: Record<string, unknown> | null; after: Record<string, unknown> | null;
  affectedItems: Record<string, unknown>[];
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
  "business_target_date_changed", "calendar_rescheduled", "calendar_reschedule_reversed",
  "schedule_hierarchy_deleted", "hierarchy_moved"];
const eventLabels: Record<ProductHistoryEventType, string> = {
  product_created: messages.productHistoryTypeProductCreated,
  schedule_imported: messages.productHistoryTypeImport,
  activity_dates_changed: messages.productHistoryTypeActivityDates,
  business_target_date_changed: messages.productHistoryTypeTargetDate,
  calendar_rescheduled: messages.productHistoryTypeCalendarReschedule,
  calendar_reschedule_reversed: messages.productHistoryTypeCalendarReversal,
  schedule_hierarchy_deleted: messages.productHistoryTypeDeletion,
  hierarchy_moved: messages.productHistoryTypeMovement
};
const detailLabels: Record<string, string> = {
  plannedStart: messages.productHistoryStart,
  plannedEnd: messages.productHistoryEnd,
  targetDate: messages.productHistoryTargetDate,
  sourceReferenceCount: messages.productHistorySourceReferences,
  affectedCount: messages.productHistoryAffectedCount,
  targetKind: messages.productHistoryItemType,
  workingDays: messages.productHistoryWorkingDays,
  calendarVersion: messages.productHistoryCalendarVersion
};

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

function isEvent(value: unknown): value is ProductHistoryEvent {
  const item = record(value);
  const detailItem = item && record(item.item);
  const hierarchy = detailItem?.hierarchy === undefined ? null : record(detailItem.hierarchy);
  return !!item && typeof item.id === "string" && typeof item.occurredAt === "string" &&
    !Number.isNaN(Date.parse(item.occurredAt)) &&
    (item.actorName === null || typeof item.actorName === "string") &&
    eventTypes.includes(item.eventType as ProductHistoryEventType) &&
    (item.item === null || (!!detailItem && typeof detailItem.kind === "string" &&
      typeof detailItem.id === "string" && (detailItem.name === null || typeof detailItem.name === "string") &&
      (detailItem.hierarchy === undefined || !!hierarchy))) &&
    (item.justification === null || typeof item.justification === "string") &&
    (item.before === null || !!record(item.before)) && (item.after === null || !!record(item.after)) &&
    Array.isArray(item.affectedItems) && item.affectedItems.every((entry) => !!record(entry));
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
  return eventLabels[event.eventType];
}

function affectsActivity(event: ProductHistoryEvent, activityId: string): boolean {
  return (event.item?.kind === "activity" && event.item.id === activityId) ||
    event.affectedItems.some((item) => item.id === activityId);
}

function displayScalar(value: unknown, key: string): string | null {
  if (typeof value === "string") {
    if (/^(plannedStart|plannedEnd|targetDate)$/.test(key) && /^\d{4}-\d{2}-\d{2}$/.test(value))
      return formatCivilDate(value);
    if (key === "targetKind") return value === "activity" ? messages.productHistoryActivityKind :
      value === "stage" ? messages.productHistoryStageKind :
        value === "discipline" ? messages.productHistoryDisciplineKind : value;
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) return value.toLocaleString("pt-BR");
  return null;
}

function detailRows(details: Record<string, unknown> | null): [string, string][] {
  if (!details) return [];
  return Object.entries(detailLabels).flatMap(([key, label]) => {
    const value = displayScalar(details[key], key);
    return value === null ? [] : [[label, value] as [string, string]];
  });
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
  if (event.eventType !== "hierarchy_moved") return eventLabels[event.eventType];
  if (event.item?.kind === "activity") return messages.productHistoryActivityMoved;
  if (event.item?.kind === "stage") return messages.productHistoryStageMoved;
  if (event.item?.kind === "discipline") return messages.productHistoryDisciplineMoved;
  return eventLabels.hierarchy_moved;
}

function MovementComparison({ event }: { event: ProductHistoryEvent }) {
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

function ActivityDateComparison({ event }: { event: ProductHistoryEvent }) {
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

function HistoryEventCard({ event }: { event: ProductHistoryEvent }) {
  const itemHierarchy = hierarchyLabel(event.item);
  const affected = event.affectedItems.filter((item) => typeof item.name === "string");
  const beforeRows = detailRows(event.before);
  const afterRows = detailRows(event.after);
  const hasMovement = event.eventType === "hierarchy_moved";
  const hasActivityDates = activityChanges(event.before).length > 0 || activityChanges(event.after).length > 0;
  const genericDetails = beforeRows.length > 0 || afterRows.length > 0;
  return <li className="product-history__event">
    <header className="product-history__event-header">
      <div className="product-history__event-main">
        <strong className="product-history__item-name">{eventItemName(event)}</strong>
        <time dateTime={event.occurredAt}>{historyTime.format(new Date(event.occurredAt))}</time>
        <span>{event.actorName ?? messages.calendarRescheduleActorUnavailable}</span>
      </div>
        <span className="product-history__event-type">{movementEventLabel(event)}</span>
    </header>
    {itemHierarchy && <p className="product-history__hierarchy">{itemHierarchy}</p>}
    {event.justification && <p className="product-history__justification">
      <strong>{messages.productHistoryJustification}:</strong> {event.justification}
    </p>}
    {affected.length > 0 && <details className="product-history__details">
      <summary>{messages.productHistoryAffected(affected.length)}</summary>
      <ul className="product-history__affected-items">{affected.map((item, index) => <li key={`${String(item.id)}:${index}`}>
        <strong>{String(item.name)}</strong>
        {hierarchyLabel(item) && <span className="product-history__hierarchy">{hierarchyLabel(item)}</span>}
      </li>)}</ul>
    </details>}
    {(genericDetails || hasActivityDates || hasMovement) && <details className="product-history__details">
      <summary>{messages.productHistoryBeforeAfter}</summary>
      {hasMovement ? <MovementComparison event={event} /> : hasActivityDates ? <ActivityDateComparison event={event} /> : <div className="product-history__value-columns">
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

  const visibleEvents = events.filter((event) => (filter === "all" || event.eventType === filter) &&
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
