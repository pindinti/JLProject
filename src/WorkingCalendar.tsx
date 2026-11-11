import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  calendarRulesForYear, type CalendarException, type CalendarExceptionInput,
  type CalendarExceptionKind
} from "../domain/working-calendar";
import { authenticatedFetch, type WorkspaceSummary } from "./auth";
import { CalendarHistoryDialog } from "./CalendarHistoryDialog";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { DatePickerField } from "./DatePickerField";
import { messages } from "./locales/pt-BR";

interface Draft {
  id: string | null;
  kind: CalendarExceptionKind;
  name: string;
  municipality: string;
  description: string;
  startDate: string;
  endDate: string;
}

function currentSaoPauloYear(): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo", year: "numeric"
  }).formatToParts(new Date());
  return Number(parts.find((part) => part.type === "year")?.value);
}

function exceptionTitle(item: CalendarException): string {
  if (item.kind === "municipal_holiday") return item.name ?? "";
  return item.kind === "collective_vacation" ? messages.calendarVacation : messages.calendarShutdown;
}

function exceptionDetail(item: CalendarException): string {
  if (item.kind === "municipal_holiday")
    return `${item.municipality} · ${formatCivilDate(item.startDate)}`;
  return `${item.description} · ${formatCivilDate(item.startDate)} a ${formatCivilDate(item.endDate)}`;
}

function historyDetail(item: CalendarException): string {
  return `${exceptionTitle(item)} — ${exceptionDetail(item)}`;
}

export function WorkingCalendar({ workspace, onAccessLost, initialYear = currentSaoPauloYear() }: {
  workspace: WorkspaceSummary;
  onAccessLost: () => void;
  initialYear?: number;
}) {
  const [year, setYear] = useState(initialYear);
  const [version, setVersion] = useState(0);
  const [exceptions, setExceptions] = useState<CalendarException[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "error">("loading");
  const [historyOpen, setHistoryOpen] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const endpoint = `/api/workspaces/${workspace.id}/calendar`;
  const canManage = workspace.role === "admin";
  const { rules, optionalDaysVerified } = calendarRulesForYear(year);
  const national = rules.filter((rule) => rule.kind === "national_holiday");
  const optional = rules.filter((rule) => rule.kind === "federal_optional");
  const local = exceptions.filter((item) => item.kind === "municipal_holiday");
  const periods = exceptions.filter((item) => item.kind !== "municipal_holiday");

  const load = useCallback(async () => {
    setState("loading");
    try {
      const response = await authenticatedFetch(`${endpoint}?year=${year}`);
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Calendar lookup failed.");
      const data = await response.json() as { calendar?: { version?: unknown; exceptions?: unknown } };
      if (!data.calendar || !Number.isSafeInteger(data.calendar.version) ||
          !Array.isArray(data.calendar.exceptions)) throw new Error("Invalid calendar response.");
      setVersion(Number(data.calendar.version));
      setExceptions(data.calendar.exceptions as CalendarException[]);
      setState("ready");
    } catch { setState("error"); }
  }, [endpoint, onAccessLost, year]);

  useEffect(() => { queueMicrotask(() => void load()); }, [load]);

  function create(kind: CalendarExceptionKind) {
    setFeedback("");
    setDraft({ id: null, kind, name: "", municipality: "", description: "", startDate: "", endDate: "" });
  }

  function edit(item: CalendarException) {
    setFeedback("");
    setDraft({ id: item.id, kind: item.kind, name: item.name ?? "",
      municipality: item.municipality ?? "", description: item.description ?? "",
      startDate: formatCivilDate(item.startDate), endDate: formatCivilDate(item.endDate) });
  }

  function prepareInput(value: Draft): CalendarExceptionInput | null {
    const startDate = parseBrazilianDate(value.startDate);
    const endDate = value.kind === "municipal_holiday" ? startDate : parseBrazilianDate(value.endDate);
    if (!startDate || !endDate || endDate < startDate) return null;
    const days = (Date.parse(`${endDate}T00:00:00Z`) - Date.parse(`${startDate}T00:00:00Z`)) / 86_400_000;
    if (days > 365) return null;
    if (value.kind === "municipal_holiday") {
      const name = value.name.trim();
      const municipality = value.municipality.trim();
      if (!name || name.length > 200 || !municipality || municipality.length > 120) return null;
      return { kind: value.kind, name, municipality, description: null, startDate, endDate };
    }
    const description = value.description.trim();
    if (!description || description.length > 500) return null;
    return { kind: value.kind, name: null, municipality: null, description, startDate, endDate };
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft || !canManage || busy) return;
    const input = prepareInput(draft);
    if (!input) { setFeedback(messages.calendarInvalid); return; }
    setBusy(true);
    setFeedback("");
    try {
      const response = await authenticatedFetch(`${endpoint}/exceptions${draft.id ? `/${draft.id}` : ""}`, {
        method: draft.id ? "PATCH" : "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...input, expectedVersion: version })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (response.status === 409) {
        const data = await response.json() as { code?: string };
        setFeedback(data.code === "duplicate" ? messages.calendarDuplicate : messages.calendarConflict);
        if (data.code !== "duplicate") await load();
        return;
      }
      if (response.status === 400) { setFeedback(messages.calendarInvalid); return; }
      if (!response.ok) throw new Error("Calendar mutation failed.");
      setDraft(null);
      await load();
      setFeedback(messages.calendarSaved);
    } catch { setFeedback(messages.calendarSaveError); }
    finally { setBusy(false); }
  }

  async function remove(item: CalendarException) {
    if (!canManage || busy || !window.confirm(messages.calendarConfirmRemove(exceptionTitle(item)))) return;
    setBusy(true);
    setFeedback("");
    try {
      const response = await authenticatedFetch(`${endpoint}/exceptions/${item.id}`, {
        method: "DELETE", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ expectedVersion: version })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (response.status === 409) { setFeedback(messages.calendarConflict); await load(); return; }
      if (!response.ok) throw new Error("Calendar removal failed.");
      await load();
      setFeedback(messages.calendarRemoved);
    } catch { setFeedback(messages.calendarSaveError); }
    finally { setBusy(false); }
  }

  function exceptionRows(items: CalendarException[], emptyMessage: string) {
    if (items.length === 0) return <p>{emptyMessage}</p>;
    return <ul className="calendar-list">{items.map((item) => <li key={item.id} className="calendar-list__row">
      <div><strong>{exceptionTitle(item)}</strong><span>{exceptionDetail(item)}</span></div>
      {canManage && <div className="calendar-list__actions">
        <button type="button" onClick={() => edit(item)} disabled={busy}>{messages.calendarEdit}</button>
        <button type="button" onClick={() => void remove(item)} disabled={busy}>{messages.calendarRemove}</button>
      </div>}
    </li>)}</ul>;
  }

  return <section className="working-calendar" aria-labelledby="working-calendar-title">
    <header className="working-calendar__heading">
      <div><h3 id="working-calendar-title">{messages.workingCalendar}</h3>
        <p>{messages.workingCalendarDescription}</p></div>
      <div className="working-calendar__header-actions">
        <button type="button" onClick={() => setHistoryOpen(true)}>{messages.calendarHistoryOpen}</button>
        <div className="working-calendar__year" aria-label={messages.calendarYear(year)}>
          <button type="button" aria-label={messages.calendarPreviousYear} disabled={year <= 2026}
            onClick={() => setYear(year - 1)}>‹</button>
          <strong>{year}</strong>
          <button type="button" aria-label={messages.calendarNextYear} disabled={year >= 2100}
            onClick={() => setYear(year + 1)}>›</button>
        </div>
      </div>
    </header>
    <p className="working-calendar__note">{messages.calendarWeekends}</p>
    {!optionalDaysVerified && <p className="settings-notice" role="note">{messages.calendarOptionalCoverage}</p>}
    {state === "loading" && <p role="status">{messages.calendarLoading}</p>}
    {state === "error" && <div role="alert"><p>{messages.calendarLoadError}</p>
      <button type="button" onClick={() => void load()}>{messages.retry}</button></div>}
    {state === "ready" && <>
      <div className="working-calendar__rules">
        <section><h4>{messages.calendarNational}</h4><ul className="calendar-rule-list">
          {national.map((rule) => <li key={rule.code}><span>{formatCivilDate(rule.date)}</span>
            <strong>{messages.calendarRuleNames[rule.code]}</strong></li>)}
        </ul></section>
        {optional.length > 0 && <section><h4>{messages.calendarOptional}</h4><ul className="calendar-rule-list">
          {optional.map((rule) => <li key={rule.code}><span>{formatCivilDate(rule.date)}</span>
            <strong>{messages.calendarRuleNames[rule.code]}</strong></li>)}
        </ul></section>}
      </div>
      <section className="working-calendar__section"><h4>{messages.calendarLocal}</h4>
        {canManage && <button type="button" onClick={() => create("municipal_holiday")} disabled={busy}>
          {messages.calendarAddLocal}</button>}
        {exceptionRows(local, messages.calendarEmptyLocal)}
      </section>
      <section className="working-calendar__section"><h4>{messages.calendarPeriods}</h4>
        {canManage && <div className="calendar-list__actions">
          <button type="button" onClick={() => create("collective_vacation")} disabled={busy}>
            {messages.calendarAddVacation}</button>
          <button type="button" onClick={() => create("company_shutdown")} disabled={busy}>
            {messages.calendarAddShutdown}</button>
        </div>}
        {exceptionRows(periods, messages.calendarEmptyPeriods)}
      </section>
    </>}
    {draft && canManage && <form className="working-calendar__form" onSubmit={(event) => void submit(event)}>
      <h4>{draft.id ? messages.calendarEdit : draft.kind === "municipal_holiday"
        ? messages.calendarAddLocal : draft.kind === "collective_vacation"
          ? messages.calendarAddVacation : messages.calendarAddShutdown}</h4>
      {draft.kind === "municipal_holiday" ? <>
        <label htmlFor="calendar-name">{messages.calendarName}</label>
        <input id="calendar-name" required maxLength={200} value={draft.name} disabled={busy}
          onChange={(event) => setDraft({ ...draft, name: event.target.value })} />
        <label htmlFor="calendar-municipality">{messages.calendarMunicipality}</label>
        <input id="calendar-municipality" required maxLength={120} value={draft.municipality} disabled={busy}
          onChange={(event) => setDraft({ ...draft, municipality: event.target.value })} />
        <label htmlFor="calendar-date">{messages.calendarDate}</label>
        <DatePickerField id="calendar-date" label={messages.calendarDate} required maxLength={10}
          value={draft.startDate} disabled={busy}
          onChange={(startDate) => setDraft({ ...draft, startDate })} />
      </> : <>
        <label htmlFor="calendar-description">{messages.calendarDescription}</label>
        <input id="calendar-description" required maxLength={500} value={draft.description} disabled={busy}
          onChange={(event) => setDraft({ ...draft, description: event.target.value })} />
        <label htmlFor="calendar-start">{messages.calendarStart}</label>
        <DatePickerField id="calendar-start" label={messages.calendarStart} required maxLength={10}
          value={draft.startDate} disabled={busy}
          onChange={(startDate) => setDraft({ ...draft, startDate })} />
        <label htmlFor="calendar-end">{messages.calendarEnd}</label>
        <DatePickerField id="calendar-end" label={messages.calendarEnd} required maxLength={10}
          value={draft.endDate} disabled={busy}
          onChange={(endDate) => setDraft({ ...draft, endDate })} />
      </>}
      <div className="calendar-list__actions"><button type="submit" disabled={busy}>
        {busy ? messages.calendarSaving : messages.calendarSave}</button>
        <button type="button" onClick={() => setDraft(null)} disabled={busy}>{messages.calendarCancel}</button>
      </div>
    </form>}
    {feedback && <p role="alert" className="feedback">{feedback}</p>}
    {historyOpen && <CalendarHistoryDialog endpoint={endpoint} onAccessLost={onAccessLost}
      onClose={() => setHistoryOpen(false)} describeException={historyDetail} exceptionTitle={exceptionTitle} />}
  </section>;
}
