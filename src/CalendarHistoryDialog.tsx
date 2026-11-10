import { useCallback, useEffect, useRef, useState } from "react";
import type { CalendarException, CalendarHistoryEntry } from "../domain/working-calendar";
import { authenticatedFetch } from "./auth";
import { ChangeHistoryDialog } from "./ChangeHistoryDialog";
import { messages } from "./locales/pt-BR";

const historyTime = new Intl.DateTimeFormat("pt-BR", {
  timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "short"
});

export function CalendarHistoryDialog({ endpoint, onAccessLost, onClose, describeException, exceptionTitle }: {
  endpoint: string; onAccessLost: () => void; onClose: () => void;
  describeException: (item: CalendarException) => string;
  exceptionTitle: (item: CalendarException) => string;
}) {
  const [entries, setEntries] = useState<CalendarHistoryEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [nextBeforeVersion, setNextBeforeVersion] = useState<number | null>(null);
  const requestSequence = useRef(0);

  const load = useCallback(async (beforeVersion: number | null) => {
    const requestId = ++requestSequence.current;
    setLoading(true);
    setError(false);
    try {
      const suffix = beforeVersion === null ? "" : `?beforeVersion=${beforeVersion}`;
      const response = await authenticatedFetch(`${endpoint}/history${suffix}`, { cache: "no-store" });
      if (requestId !== requestSequence.current) return;
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Calendar history lookup failed.");
      const data = await response.json() as { history?: { entries?: unknown; nextBeforeVersion?: unknown } };
      const page = data.history;
      if (!page || !Array.isArray(page.entries) ||
          (page.nextBeforeVersion !== null && !Number.isSafeInteger(page.nextBeforeVersion)))
        throw new Error("Invalid calendar history response.");
      if (requestId !== requestSequence.current) return;
      setEntries((previous) => beforeVersion === null ? page.entries as CalendarHistoryEntry[]
        : [...previous, ...page.entries as CalendarHistoryEntry[]]);
      setNextBeforeVersion(page.nextBeforeVersion as number | null);
    } catch {
      if (requestId === requestSequence.current) setError(true);
    } finally {
      if (requestId === requestSequence.current) setLoading(false);
    }
  }, [endpoint, onAccessLost]);

  useEffect(() => {
    queueMicrotask(() => void load(null));
    return () => { requestSequence.current += 1; };
  }, [load]);

  const actionLabel = (action: CalendarHistoryEntry["action"]) => action === "created"
    ? messages.calendarCreated : action === "updated" ? messages.calendarUpdated : messages.calendarRemovedAction;

  return <ChangeHistoryDialog title={messages.calendarHistory} closeLabel={messages.calendarHistoryClose}
    onClose={onClose} footer={<div className="calendar-history__footer">
      {nextBeforeVersion !== null && <button type="button" disabled={loading}
        onClick={() => void load(nextBeforeVersion)}>{messages.calendarHistoryMore}</button>}
      <button type="button" onClick={onClose}>{messages.closeHistory}</button>
    </div>}>
    {loading && entries.length === 0 && <p role="status">{messages.calendarHistoryLoading}</p>}
    {error && <div role="alert"><p>{messages.calendarHistoryError}</p>
      <button type="button" onClick={() => void load(entries.length ? nextBeforeVersion : null)}>
        {messages.retry}</button></div>}
    {!loading && !error && entries.length === 0 && <p>{messages.calendarEmptyHistory}</p>}
    {entries.length > 0 && <ol className="calendar-history">{entries.map((entry) => <li key={entry.operationId}>
      <div className="calendar-history__card-header">
        <div className="calendar-history__identity">
          <strong>{exceptionTitle(entry.after)}</strong>
          <time dateTime={entry.changedAt}>{historyTime.format(new Date(entry.changedAt))}</time>
          <span>{entry.actorName ?? messages.calendarActorUnknown}</span>
        </div>
        <span className="calendar-history__badge">{actionLabel(entry.action)}</span>
      </div>
      <details><summary>{messages.calendarHistoryDetails}</summary>
        <dl className="calendar-history__values">
          {entry.before && <div><dt>{messages.calendarBefore}</dt><dd>{describeException(entry.before)}</dd></div>}
          <div><dt>{messages.calendarAfter}</dt><dd>{entry.action === "removed"
            ? `${messages.calendarRemovedAction}: ${describeException(entry.after)}`
            : describeException(entry.after)}</dd></div>
        </dl>
      </details>
    </li>)}</ol>}
  </ChangeHistoryDialog>;
}
