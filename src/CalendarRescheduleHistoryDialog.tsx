import { type KeyboardEvent, type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { authenticatedFetch } from "./auth";
import { formatCivilDate } from "./civil-date";
import { messages } from "./locales/pt-BR";

type HistoryActivity = {
  activityId: string; name: string | null; previousStart: string; previousEnd: string;
  newStart: string; newEnd: string; currentStart: string | null; currentEnd: string | null;
};
type HistoryOperation = {
  operationId: string; changedAt: string; actorName: string | null; reason: string;
  status: "eligible" | "already_reversed" | "conflict";
  reversal: { changedAt: string; actorName: string | null; reason: string } | null;
  activities: HistoryActivity[];
};
type HistoryState = "loading" | "ready" | "error";
type HistoryHierarchy = { disciplines: Array<{ name: string; stages: Array<{
  displayName: string; activities: Array<{ id: string }>
}> }> };

const auditDateTime = new Intl.DateTimeFormat("pt-BR", {
  dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo"
});

function parseHistoryPayload(value: unknown): HistoryOperation[] | null {
  if (!value || typeof value !== "object" || !Array.isArray((value as { operations?: unknown }).operations)) return null;
  const operations = (value as { operations: unknown[] }).operations;
  for (const operation of operations) {
    if (!operation || typeof operation !== "object") return null;
    const item = operation as Record<string, unknown>;
    if (typeof item["operationId"] !== "string" || typeof item["changedAt"] !== "string" ||
        !Number.isFinite(Date.parse(item["changedAt"])) ||
        (item["actorName"] !== null && typeof item["actorName"] !== "string") ||
        typeof item["reason"] !== "string" ||
        !["eligible", "already_reversed", "conflict"].includes(String(item["status"])) ||
        !Array.isArray(item["activities"])) return null;
    if (item["reversal"] !== null) {
      if (!item["reversal"] || typeof item["reversal"] !== "object") return null;
      const reversal = item["reversal"] as Record<string, unknown>;
      if (typeof reversal["changedAt"] !== "string" || !Number.isFinite(Date.parse(reversal["changedAt"])) ||
          (reversal["actorName"] !== null && typeof reversal["actorName"] !== "string") ||
          typeof reversal["reason"] !== "string") return null;
    }
    for (const activity of item["activities"]) {
      if (!activity || typeof activity !== "object") return null;
      const row = activity as Record<string, unknown>;
      if (["activityId", "previousStart", "previousEnd", "newStart", "newEnd"]
        .some((key) => typeof row[key] !== "string") ||
        (row["name"] !== null && typeof row["name"] !== "string") ||
        (row["currentStart"] !== null && typeof row["currentStart"] !== "string") ||
        (row["currentEnd"] !== null && typeof row["currentEnd"] !== "string")) return null;
    }
  }
  return operations as HistoryOperation[];
}

export function ChangeHistoryDialog({ title, closeLabel, onClose, children, footer }: {
  title: string; closeLabel: string; onClose: () => void; children: ReactNode; footer: ReactNode;
}) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);
  useEffect(() => {
    previousFocus.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialogRef.current?.querySelector<HTMLElement>("button, input, textarea, [tabindex='0']")?.focus();
    return () => queueMicrotask(() => previousFocus.current?.focus());
  }, []);
  function handleKeys(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") { event.preventDefault(); onClose(); return; }
    if (event.key !== "Tab" || !dialogRef.current) return;
    const items = [...dialogRef.current.querySelectorAll<HTMLElement>(
      "button:not(:disabled), input:not(:disabled), textarea:not(:disabled), [tabindex='0']"
    )].filter((item) => item.getAttribute("aria-hidden") !== "true");
    if (!items.length) return;
    const first = items[0]; const last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }
  return <div className="change-history-backdrop" onMouseDown={(event) => {
    if (event.target === event.currentTarget) onClose();
  }}>
    <section ref={dialogRef} className="change-history-dialog" role="dialog" aria-modal="true"
      aria-labelledby="change-history-title" onKeyDown={handleKeys}>
      <header className="change-history-dialog__header">
        <h2 id="change-history-title">{title}</h2>
        <button type="button" className="change-history-dialog__close" aria-label={closeLabel}
          title={closeLabel} onClick={onClose}>×</button>
      </header>
      <div className="change-history-dialog__body">{children}</div>
      <footer className="change-history-dialog__footer">{footer}</footer>
    </section>
  </div>;
}

export function CalendarRescheduleHistoryDialog({ base, hierarchy, canEdit, onClose, onAccessLost, onReversed }: {
  base: string; hierarchy: HistoryHierarchy | null; canEdit: boolean; onClose: () => void; onAccessLost: () => void;
  onReversed: () => Promise<void>;
}) {
  const [operations, setOperations] = useState<HistoryOperation[]>([]);
  const [historyState, setHistoryState] = useState<HistoryState>("loading");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const requestSequence = useRef(0);
  const submitting = useRef(false);
  const confirmRef = useRef<HTMLDivElement>(null);
  const reasonRef = useRef<HTMLTextAreaElement>(null);
  const activityPaths = useMemo(() => {
    const paths = new Map<string, string>();
    for (const discipline of hierarchy?.disciplines ?? []) {
      for (const stage of discipline.stages) {
        for (const activity of stage.activities) paths.set(activity.id, `${discipline.name} › ${stage.displayName}`);
      }
    }
    return paths;
  }, [hierarchy]);

  const loadHistory = useCallback(async () => {
    const requestId = ++requestSequence.current;
    setHistoryState("loading");
    setFeedback("");
    try {
      const response = await authenticatedFetch(`${base}/calendar-reschedules/history`, { cache: "no-store" });
      if (requestId !== requestSequence.current) return;
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Reschedule history lookup failed.");
      const parsed = parseHistoryPayload(await response.json());
      if (!parsed || requestId !== requestSequence.current) throw new Error("Invalid reschedule history response.");
      setOperations(parsed);
      setSelectedId((current) => current && parsed.some((item) => item.operationId === current && item.status === "eligible")
        ? current : null);
      setHistoryState("ready");
    } catch {
      if (requestId === requestSequence.current) setHistoryState("error");
    }
  }, [base, onAccessLost]);

  useEffect(() => {
    queueMicrotask(() => void loadHistory());
    return () => { requestSequence.current += 1; };
  }, [loadHistory]);

  useEffect(() => {
    if (confirmOpen) confirmRef.current?.querySelector<HTMLElement>("button")?.focus();
  }, [confirmOpen]);

  const selected = operations.find((operation) => operation.operationId === selectedId && operation.status === "eligible");
  async function performReverse() {
    if (!selected || reason.trim().length < 10 || submitting.current) return;
    submitting.current = true;
    setBusy(true); setFeedback("");
    try {
      const response = await authenticatedFetch(`${base}/calendar-reschedules/${selected.operationId}/reverse`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ reason: reason.trim() })
      });
      if (response.status === 401) { onAccessLost(); setFeedback(messages.calendarRescheduleReverseForbidden); return; }
      if (response.status === 403) { setFeedback(messages.calendarRescheduleReverseForbidden); return; }
      if (response.status === 409) {
        const conflict = await response.json().catch(() => ({})) as { code?: unknown };
        setFeedback(conflict.code === "already_reversed" ? messages.calendarRescheduleReverseAlready
          : messages.calendarRescheduleReverseConflict);
        return;
      }
      if (response.status === 400) { setFeedback(messages.calendarRescheduleReverseInvalid); return; }
      if (!response.ok) { setFeedback(messages.calendarRescheduleReverseError); return; }
      const payload = await response.json() as { reversedCount?: unknown };
      if (!Number.isSafeInteger(payload.reversedCount) || Number(payload.reversedCount) < 1) {
        setFeedback(messages.calendarRescheduleReverseError); return;
      }
      setConfirmOpen(false);
      setReason(""); setSelectedId(null);
      const successMessage = messages.calendarRescheduleReverseSuccess(Number(payload.reversedCount));
      await onReversed();
      await loadHistory();
      setFeedback(successMessage);
    } catch { setFeedback(messages.calendarRescheduleReverseError); }
    finally { submitting.current = false; setBusy(false); }
  }

  const statusText = (status: HistoryOperation["status"]) => status === "eligible"
    ? messages.calendarRescheduleEligible : status === "already_reversed"
      ? messages.calendarRescheduleAlreadyReversed : messages.calendarRescheduleConflict;

  return <ChangeHistoryDialog title={messages.calendarRescheduleHistory}
    closeLabel={messages.calendarRescheduleClose} onClose={onClose}
    footer={<>
      {canEdit ? <form className="reschedule-history__form" onSubmit={(event) => {
        event.preventDefault();
        if (!selected || reason.trim().length < 10) { setFeedback(messages.calendarRescheduleReasonRequired); return; }
        setFeedback(""); setConfirmOpen(true);
      }}>
        <p>{messages.calendarRescheduleReversalExplanation}</p>
        <p>{messages.calendarRescheduleWholeBatch}</p>
        {!selected && <p className="reschedule-history__hint">{messages.calendarRescheduleNoSelection}</p>}
        {selected && <button type="button" className="reschedule-history__clear" disabled={busy}
          onClick={() => setSelectedId(null)}>{messages.calendarRescheduleClearSelection}</button>}
        <label htmlFor="reschedule-reversal-reason">{messages.calendarRescheduleReversalReason}</label>
        <textarea ref={reasonRef} id="reschedule-reversal-reason" value={reason} maxLength={2000} rows={2}
          disabled={busy} onChange={(event) => setReason(event.target.value)} />
        <div className="reschedule-history__actions">
          <button type="button" disabled={busy || historyState === "loading"} onClick={() => void loadHistory()}>
            {messages.calendarImpactRefresh}
          </button>
          <button type="submit" disabled={busy || !selected || reason.trim().length < 10}>
            {messages.calendarRescheduleReversalSubmit}
          </button>
        </div>
      </form> : <div className="reschedule-history__viewer-footer">
        <p>{messages.calendarRescheduleReadOnly}</p>
        <button type="button" disabled={historyState === "loading"} onClick={() => void loadHistory()}>
          {messages.calendarImpactRefresh}
        </button>
      </div>}
    </>}>
    <p className="reschedule-history__provisional" role="note">{messages.calendarRescheduleHistoryProvisional}</p>
    {feedback && <p className="reschedule-history__feedback" role="status">{feedback}</p>}
    {historyState === "loading" && <p role="status">{messages.calendarRescheduleHistoryLoading}</p>}
    {historyState === "error" && <div role="alert"><p>{messages.calendarRescheduleHistoryError}</p>
      <button type="button" onClick={() => void loadHistory()}>{messages.retry}</button></div>}
    {historyState === "ready" && operations.length === 0 && <p>{messages.calendarRescheduleHistoryEmpty}</p>}
    {historyState === "ready" && operations.length > 0 && <ol className="reschedule-history__list">
      {operations.map((operation) => <li key={operation.operationId} className="reschedule-history__operation"
        data-status={operation.status}>
        <div className="reschedule-history__operation-header">
          <div className="reschedule-history__operation-meta">
            <time dateTime={operation.changedAt}>{auditDateTime.format(new Date(operation.changedAt))}</time>
            <span>{messages.calendarRescheduleOperationBy(operation.actorName ?? messages.calendarRescheduleActorUnavailable)}</span>
            <span>{messages.calendarRescheduleActivityCount(operation.activities.length)}</span>
          </div>
          <span className={`reschedule-history__status reschedule-history__status--${operation.status}`}>
            {statusText(operation.status)}
          </span>
        </div>
        <div className="reschedule-history__operation-action">
          {canEdit && operation.status === "eligible" && <label className="reschedule-history__selector">
            <input type="radio" name="calendar-reschedule-operation" value={operation.operationId}
              checked={selectedId === operation.operationId} disabled={busy}
              onChange={() => setSelectedId(operation.operationId)} />
            <span>{messages.calendarRescheduleSelect}</span>
          </label>}
          <p><strong>{messages.calendarRescheduleReason}:</strong> {operation.reason}</p>
        </div>
        <details open={selectedId === operation.operationId}>
          <summary>{messages.calendarRescheduleShowActivities}</summary>
          <ul className="reschedule-history__activities">
            {operation.activities.map((activity) => <li key={activity.activityId}>
              <strong>{activityPaths.has(activity.activityId)
                ? `${activityPaths.get(activity.activityId)} › ${activity.name ?? messages.calendarRescheduleActivityUnavailable}`
                : activity.name ?? messages.calendarRescheduleActivityUnavailable}</strong>
              {!activityPaths.has(activity.activityId) && <span className="reschedule-history__path-unavailable">
                {messages.calendarRescheduleHierarchyUnavailable}
              </span>}
              <div className="reschedule-history__dates">
                <span>{messages.calendarRescheduleBefore(formatCivilDate(activity.previousStart), formatCivilDate(activity.previousEnd))}</span>
                <span>{messages.calendarRescheduleAfter(formatCivilDate(activity.newStart), formatCivilDate(activity.newEnd))}</span>
              </div>
              {operation.status === "conflict" && <p className="reschedule-history__current">
                {messages.calendarRescheduleCurrent(formatCivilDate(activity.currentStart), formatCivilDate(activity.currentEnd))}
              </p>}
            </li>)}
          </ul>
        </details>
        {operation.reversal && <div className="reschedule-history__reversal">
          <p>{messages.calendarRescheduleReversalRecorded(
            auditDateTime.format(new Date(operation.reversal.changedAt)),
            operation.reversal.actorName ?? messages.calendarRescheduleActorUnavailable)}</p>
          <p>{messages.calendarRescheduleReversalReasonValue(operation.reversal.reason)}</p>
        </div>}
      </li>)}
    </ol>}
    {confirmOpen && <div className="change-history-confirm-backdrop">
      <div ref={confirmRef} className="change-history-confirm" role="alertdialog" aria-modal="true"
        aria-labelledby="reschedule-confirm-title" aria-describedby="reschedule-confirm-description">
        <h3 id="reschedule-confirm-title">{messages.calendarRescheduleConfirmTitle}</h3>
        <p id="reschedule-confirm-description">{messages.calendarRescheduleConfirmDescription}</p>
        <p>{messages.calendarRescheduleReversalExplanation}</p>
        <div className="change-history-confirm__actions" onKeyDown={(event) => {
          if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setConfirmOpen(false); }
        }}>
          <button type="button" disabled={busy} onClick={() => {
            setConfirmOpen(false); queueMicrotask(() => reasonRef.current?.focus());
          }}>{messages.cancel}</button>
          <button type="button" disabled={busy} onClick={() => void performReverse()}>
            {busy ? messages.calendarImpactApplying : messages.calendarRescheduleConfirmAction}</button>
        </div>
      </div>
    </div>}
  </ChangeHistoryDialog>;
}
