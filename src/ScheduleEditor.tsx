import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { authenticatedFetch, type WorkspaceSummary } from "./auth";
import { messages } from "./locales/pt-BR";
import { ColorField } from "./ColorField";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { ScheduleWorkspace } from "./ScheduleWorkspace";
import type { ScheduleTarget, VisibleRow } from "../domain/schedule-workspace";
import { dayNumber } from "../domain/schedule-workspace";
import type { ActivityCalendarImpact } from "../domain/calendar-impact";
import type { SkippedDateReason, SkippedWorkingDate } from "../domain/working-day-calculation";

export interface ScheduleProduct { id: string; name: string; active: boolean }
interface Activity {
  id: string; stageId: string; name: string; activityType: string | null;
  plannedStart: string | null; plannedEnd: string | null;
  displayOrder: number; notes: string | null; version: number;
  planningMode: "manual" | "working_days"; workingDayDuration: number | null;
  planningCalendarVersion: number | null;
}
interface Stage {
  id: string; disciplineId: string; code: string; color: string; displayName: string;
  displayOrder: number; derivedStart: string | null; derivedEnd: string | null;
  version: number; activities: Activity[];
}
interface Discipline {
  id: string; productId: string; name: string; shortCode: string; color: string;
  displayOrder: number; description: string | null; version: number; stages: Stage[];
}
interface Hierarchy { productId: string; disciplines: Discipline[] }
interface StageDefinition { id: string; code: string; color: string }
interface WorkingPreview {
  startDate: string; endDate: string; workingDays: number; skippedDates: SkippedWorkingDate[];
  optionalDaysVerified: boolean; unverifiedOptionalYears: number[]; calendarVersion: number;
}
function previewMatches(preview: WorkingPreview | null, start: string, duration: string): preview is WorkingPreview {
  const parsedStart = parseBrazilianDate(start);
  return !!preview && !!parsedStart && preview.startDate === parsedStart &&
    /^\d+$/.test(duration) && preview.workingDays === Number(duration);
}
interface DateDraft {
  originalStart: string; originalEnd: string; plannedStart: string; plannedEnd: string; reason: string;
  version: number; planningMode: "manual" | "working_days"; workingDays: string;
  originalPlanningMode: "manual" | "working_days"; originalWorkingDays: number | null;
  originalCalendarVersion: number | null;
}
interface HistorySubject { id: string; disciplineId: string; stageId: string; name: string }
interface CalendarImpactResponse { calendarVersion: number; impacts: ActivityCalendarImpact[] }
interface DateChange { operationId: string; changedAt: string; previousStart: string | null;
  previousEnd: string | null; newStart: string; newEnd: string; reason: string }
const auditDate = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo",
  day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });
type DraftKind = "discipline" | "stage" | "activity";
interface Draft {
  kind: DraftKind; id?: string; disciplineId?: string; stageId?: string; version?: number;
  name: string; shortCode: string; code: string; color: string; displayName: string;
  displayOrder: string; description: string; activityType: string;
  plannedStart: string; plannedEnd: string; notes: string; definitionId: string;
  planningMode: "manual" | "working_days"; workingDays: string;
}
const newDefinition = "new";

function initialDraft(kind: DraftKind): Draft {
  return { kind, name: "", shortCode: "", code: "", color: "#336699", displayName: "",
    displayOrder: "0", description: "", activityType: "", plannedStart: "", plannedEnd: "",
    notes: "", definitionId: newDefinition, planningMode: "manual", workingDays: "" };
}

function workingReason(reason: SkippedDateReason): string {
  const label = reason.kind === "weekend" ? messages.workingDayWeekend(reason.code)
    : messages.workingDayReasonLabels[reason.kind];
  const detail = reason.kind === "municipal_holiday" ? reason.name ?? reason.municipality
    : reason.kind === "collective_vacation" || reason.kind === "company_shutdown"
      ? reason.description : null;
  return detail ? `${label}: ${detail}` : label;
}

function WorkingPreviewDetails({ preview, loading }: { preview: WorkingPreview | null; loading: boolean }) {
  if (loading) return <p role="status">{messages.workingDayLoading}</p>;
  if (!preview) return null;
  return <section className="working-day-preview" aria-live="polite">
    <p><strong>{messages.workingDayProposedEnd}:</strong> {formatCivilDate(preview.endDate)}</p>
    {!preview.optionalDaysVerified && <p role="status" className="working-day-preview__warning">
      {messages.workingDayCoverageWarning(preview.unverifiedOptionalYears.join(", "))}
    </p>}
    <p>{messages.workingDaySkippedCount(preview.skippedDates.length)}</p>
    {preview.skippedDates.length === 0 ? <p>{messages.workingDayNoSkipped}</p> :
      <ul aria-label={messages.workingDaySkipped}>
        {preview.skippedDates.map((item) => <li key={item.date}>
          {formatCivilDate(item.date)} — {item.reasons.map(workingReason).join(", ")}
        </li>)}
      </ul>}
  </section>;
}

export function ScheduleEditor({ workspace, product, onBack, onAccessLost }: {
  workspace: WorkspaceSummary; product: ScheduleProduct;
  onBack: () => void; onAccessLost: () => void;
}) {
  const [hierarchy, setHierarchy] = useState<Hierarchy | null>(null);
  const [definitions, setDefinitions] = useState<StageDefinition[]>([]);
  const [targets, setTargets] = useState<ScheduleTarget[]>([]);
  const [state, setState] = useState<"loading" | "ready" | "error" | "notFound">("loading");
  const [openDisciplines, setOpenDisciplines] = useState<Set<string> | null>(null);
  const [openStages, setOpenStages] = useState<Set<string> | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dateDraft, setDateDraft] = useState<DateDraft | null>(null);
  const [workingPreview, setWorkingPreview] = useState<WorkingPreview | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);
  const workingPreviewRequest = useRef(0);
  const [historySubject, setHistorySubject] = useState<HistorySubject | null>(null);
  const [history, setHistory] = useState<DateChange[]>([]);
  const [historyState, setHistoryState] = useState<"loading" | "ready" | "error">("loading");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const [impactState, setImpactState] = useState<"idle" | "loading" | "ready" | "error">("idle");
  const [impactData, setImpactData] = useState<CalendarImpactResponse | null>(null);
  const [impactOpen, setImpactOpen] = useState(false);
  const impactRequest = useRef(0);
  const impactPanelRef = useRef<HTMLElement>(null);
  const impactTriggerRef = useRef<HTMLElement | null>(null);
  const drawerRef = useRef<HTMLDivElement>(null);
  const previousFocus = useRef<HTMLElement | null>(null);
  const historyRequest = useRef(0);
  const canEdit = product.active && (workspace.role === "admin" || workspace.role === "editor");
  const base = `/api/workspaces/${workspace.id}/products/${product.id}`;

  const refreshImpacts = useCallback(async () => {
    const requestId = ++impactRequest.current;
    setImpactState("loading");
    setImpactData(null);
    try {
      const result = await authenticatedFetch(`${base}/calendar-impact`);
      if (requestId !== impactRequest.current) return;
      if (result.status === 401 || result.status === 403) { onAccessLost(); return; }
      if (!result.ok) throw new Error("Calendar impact lookup failed.");
      const payload = await result.json() as CalendarImpactResponse;
      if (!Number.isSafeInteger(payload?.calendarVersion) || !Array.isArray(payload?.impacts) ||
          payload.impacts.some((item) => !item || typeof item.activityId !== "string" ||
            !["date_change", "version_only"].includes(item.impact))) {
        throw new Error("Invalid calendar impact response.");
      }
      setImpactData(payload);
      setImpactState("ready");
      if (payload.impacts.length === 0) setImpactOpen(false);
    } catch { if (requestId === impactRequest.current) setImpactState("error"); }
  }, [base, onAccessLost]);

  const loadHistory = useCallback(async (subject: HistorySubject) => {
    const requestId = ++historyRequest.current;
    setHistoryState("loading");
    try {
      const result = await authenticatedFetch(`${base}/disciplines/${subject.disciplineId}/stages/${subject.stageId}/activities/${subject.id}/date-history`);
      if (requestId !== historyRequest.current) return;
      if (result.status === 401 || result.status === 403) { onAccessLost(); return; }
      if (!result.ok) throw new Error("History lookup failed.");
      const changes = (await result.json() as { changes: DateChange[] }).changes;
      if (!Array.isArray(changes)) throw new Error("Invalid history response.");
      if (requestId !== historyRequest.current) return;
      setHistory(changes);
      setHistoryState("ready");
    } catch { if (requestId === historyRequest.current) setHistoryState("error"); }
  }, [base, onAccessLost]);

  const load = useCallback(async (showLoading = true) => {
    if (showLoading) setState("loading");
    try {
      const [treeResponse, targetsResponse, definitionsResponse] = await Promise.all([
        authenticatedFetch(`${base}/hierarchy`),
        authenticatedFetch(`${base}/targets`),
        canEdit ? authenticatedFetch(`/api/workspaces/${workspace.id}/stage-definitions`) : Promise.resolve(null)
      ]);
      if ([treeResponse, targetsResponse, definitionsResponse].some((result) => result?.status === 401 || result?.status === 403)) {
        onAccessLost(); return;
      }
      if (treeResponse.status === 404) { setState("notFound"); return; }
      if (!treeResponse.ok || !targetsResponse.ok || (definitionsResponse && !definitionsResponse.ok))
        throw new Error("Schedule lookup failed.");
      const tree = (await treeResponse.json() as { hierarchy: Hierarchy }).hierarchy;
      const targetList = (await targetsResponse.json() as { targets: ScheduleTarget[] }).targets;
      const catalog = definitionsResponse
        ? (await definitionsResponse.json() as { stageDefinitions: StageDefinition[] }).stageDefinitions : [];
      setHierarchy(tree);
      setTargets(targetList);
      setDefinitions(catalog);
      setOpenDisciplines((previous) => previous ?? new Set(tree.disciplines.map((item) => item.id)));
      setOpenStages((previous) => previous ?? new Set(tree.disciplines.flatMap((item) => item.stages.map((stage) => stage.id))));
      setState("ready");
    } catch { setState("error"); }
  }, [base, canEdit, onAccessLost, workspace.id]);

  async function calculateWorkingPreview(startText: string, durationText: string) {
    const requestId = ++workingPreviewRequest.current;
    setWorkingPreview(null);
    setPreviewLoading(false);
    const startDate = parseBrazilianDate(startText);
    const workingDays = Number(durationText);
    if (!startDate || !/^\d+$/.test(durationText) || !Number.isSafeInteger(workingDays) ||
        workingDays < 1 || workingDays > 27393) {
      setFeedback(messages.workingDayInvalid);
      return;
    }
    setPreviewLoading(true);
    setFeedback("");
    try {
      const query = new URLSearchParams({ startDate, workingDays: String(workingDays) });
      const result = await authenticatedFetch(`/api/workspaces/${workspace.id}/calendar/working-day-preview?${query}`);
      if (requestId !== workingPreviewRequest.current) return;
      if (result.status === 401 || result.status === 403) { onAccessLost(); return; }
      if (result.status === 409) { setFeedback(messages.workingDayCalendarChanged); return; }
      if (!result.ok) { setFeedback(messages.workingDayPreviewError); return; }
      const data = await result.json() as { preview?: WorkingPreview };
      const preview = data.preview;
      if (!preview || preview.startDate !== startDate || preview.workingDays !== workingDays ||
          !/^\d{4}-\d{2}-\d{2}$/.test(preview.endDate) || !Array.isArray(preview.skippedDates) ||
          !Number.isSafeInteger(preview.calendarVersion) || !Array.isArray(preview.unverifiedOptionalYears) ||
          typeof preview.optionalDaysVerified !== "boolean") throw new Error("Invalid working-day preview.");
      setWorkingPreview(preview);
    } catch { if (requestId === workingPreviewRequest.current) setFeedback(messages.workingDayPreviewError); }
    finally { if (requestId === workingPreviewRequest.current) setPreviewLoading(false); }
  }

  const clearWorkingPreview = useCallback(() => {
    workingPreviewRequest.current++;
    setWorkingPreview(null);
    setPreviewLoading(false);
  }, []);

  const closeDraft = useCallback(() => {
    historyRequest.current++;
    setDraft(null);
    setDateDraft(null);
    clearWorkingPreview();
    setHistorySubject(null);
    setFeedback("");
    queueMicrotask(() => previousFocus.current?.focus());
  }, [clearWorkingPreview]);

  useEffect(() => { queueMicrotask(() => void load()); }, [load]);
  useEffect(() => {
    if (state === "ready" && hierarchy) queueMicrotask(() => void refreshImpacts());
  }, [state, hierarchy, refreshImpacts]);
  useEffect(() => { if (historySubject) queueMicrotask(() => void loadHistory(historySubject)); }, [historySubject, loadHistory]);

  useEffect(() => {
    if (!impactOpen) return;
    queueMicrotask(() => impactPanelRef.current?.querySelector<HTMLElement>("button")?.focus());
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        setImpactOpen(false);
        queueMicrotask(() => impactTriggerRef.current?.focus());
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [impactOpen]);

  useEffect(() => {
    if (!draft && !historySubject) return;
    queueMicrotask(() => {
      if (!drawerRef.current?.contains(document.activeElement))
        drawerRef.current?.querySelector<HTMLElement>(draft ? "input, select, textarea" : "button")?.focus();
    });
    const keyboard = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !busy) { event.preventDefault(); closeDraft(); return; }
      if (event.key !== "Tab" || !drawerRef.current) return;
      const controls = [...drawerRef.current.querySelectorAll<HTMLElement>("button:not(:disabled), input, select, textarea")]
        .filter((element) => element.tabIndex !== -1);
      const first = controls[0]; const last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    };
    window.addEventListener("keydown", keyboard);
    return () => window.removeEventListener("keydown", keyboard);
  }, [draft, historySubject, busy, closeDraft]);

  function rememberFocus() {
    previousFocus.current = document.activeElement as HTMLElement | null;
    setImpactOpen(false);
  }

  function toggle(id: string, level: "discipline" | "stage") {
    const update = (previous: Set<string> | null) => {
      const next = new Set(previous ?? []);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    };
    if (level === "discipline") setOpenDisciplines(update); else setOpenStages(update);
  }

  function startDiscipline(item?: Discipline) {
    rememberFocus();
    setDateDraft(null);
    clearWorkingPreview();
    setHistorySubject(null);
    setFeedback("");
    setDraft(item ? { ...initialDraft("discipline"), id: item.id, version: item.version,
      name: item.name, shortCode: item.shortCode, color: item.color,
      displayOrder: String(item.displayOrder), description: item.description ?? "" }
      : initialDraft("discipline"));
  }
  function startStage(disciplineId: string, item?: Stage) {
    rememberFocus();
    setDateDraft(null);
    clearWorkingPreview();
    setHistorySubject(null);
    const match = item && definitions.find((definition) => definition.code.toLowerCase() === item.code.toLowerCase());
    setFeedback("");
    setDraft(item ? { ...initialDraft("stage"), id: item.id, version: item.version, disciplineId,
      code: item.code, color: item.color, displayName: item.displayName,
      displayOrder: String(item.displayOrder), definitionId: match?.id ?? newDefinition }
      : { ...initialDraft("stage"), disciplineId });
  }
  function startActivity(disciplineId: string, stageId: string, item?: Activity) {
    rememberFocus();
    setFeedback("");
    historyRequest.current++;
    setHistory([]);
    setHistoryState("loading");
    clearWorkingPreview();
    setHistorySubject(item ? { id: item.id, disciplineId, stageId, name: item.name } : null);
    setDateDraft(item ? { originalStart: formatCivilDate(item.plannedStart),
      originalEnd: formatCivilDate(item.plannedEnd), plannedStart: item.plannedStart ? formatCivilDate(item.plannedStart) : "",
      plannedEnd: item.plannedEnd ? formatCivilDate(item.plannedEnd) : "", reason: "", version: item.version,
      planningMode: item.planningMode, workingDays: item.workingDayDuration?.toString() ?? "",
      originalPlanningMode: item.planningMode, originalWorkingDays: item.workingDayDuration,
      originalCalendarVersion: item.planningCalendarVersion } : null);
    if (item?.planningMode === "working_days" && item.plannedStart && item.workingDayDuration)
      void calculateWorkingPreview(formatCivilDate(item.plannedStart), String(item.workingDayDuration));
    setDraft(item ? { ...initialDraft("activity"), id: item.id, version: item.version,
      disciplineId, stageId, name: item.name, activityType: item.activityType ?? "",
      plannedStart: formatCivilDate(item.plannedStart), plannedEnd: formatCivilDate(item.plannedEnd),
      displayOrder: String(item.displayOrder), notes: item.notes ?? "" }
      : { ...initialDraft("activity"), disciplineId, stageId });
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft || !canEdit || busy) return;
    if (draft.kind === "stage" && draft.definitionId !== newDefinition && selectedStageDefinition &&
        draft.color.toUpperCase() !== selectedStageDefinition.color.toUpperCase()) {
      setFeedback(messages.saveSharedColorFirst); return;
    }
    if (draft.kind === "activity" && draft.id && dateDraft &&
        (dateDraft.plannedStart !== (draft.plannedStart === messages.noDate ? "" : draft.plannedStart) ||
         dateDraft.plannedEnd !== (draft.plannedEnd === messages.noDate ? "" : draft.plannedEnd))) {
      setFeedback(messages.saveDatesSeparately); return;
    }
    const displayOrder = Number(draft.displayOrder);
    if (!/^\d+$/.test(draft.displayOrder) || !Number.isSafeInteger(displayOrder) || displayOrder > 1000000) {
      setFeedback(messages.scheduleInvalidOrder); return;
    }
    const plannedStart = draft.plannedStart ? parseBrazilianDate(draft.plannedStart) : null;
    const plannedEnd = draft.plannedEnd ? parseBrazilianDate(draft.plannedEnd) : null;
    if (draft.kind === "activity" && !draft.id) {
      if (draft.planningMode === "manual" &&
          ((!!draft.plannedStart !== !!draft.plannedEnd) ||
           (!!draft.plannedStart && (!plannedStart || !plannedEnd || plannedStart > plannedEnd)))) {
        setFeedback(messages.scheduleInvalidDates); return;
      }
      if (draft.planningMode === "working_days" &&
          (!plannedStart || !/^\d+$/.test(draft.workingDays) ||
           !previewMatches(workingPreview, draft.plannedStart, draft.workingDays))) {
        setFeedback(messages.workingDayPreviewRequired); return;
      }
    }
    if (draft.id && !window.confirm(messages.confirmHierarchyEdit)) return;
    let path = `${base}/disciplines`;
    let data: Record<string, unknown>;
    if (draft.kind === "discipline") {
      data = { name: draft.name, shortCode: draft.shortCode, color: draft.color,
        displayOrder, description: draft.description || null };
      if (draft.id) path += `/${draft.id}`;
    } else if (draft.kind === "stage") {
      path += `/${draft.disciplineId}/stages`;
      data = { code: draft.code, color: draft.color, displayName: draft.displayName, displayOrder };
      if (draft.id) path += `/${draft.id}`;
    } else {
      path += `/${draft.disciplineId}/stages/${draft.stageId}/activities`;
      data = { name: draft.name, activityType: draft.activityType || null,
        displayOrder, notes: draft.notes || null };
      if (!draft.id && draft.planningMode === "working_days" && previewMatches(workingPreview, draft.plannedStart, draft.workingDays)) {
        data = { ...data, planningMode: "working_days", plannedStart,
          workingDays: Number(draft.workingDays), calendarVersion: workingPreview.calendarVersion };
      } else if (!draft.id) data = { ...data, planningMode: "manual", plannedStart, plannedEnd };
      if (draft.id) path += `/${draft.id}`;
    }
    if (draft.id) data.version = draft.version;
    setBusy(true);
    setFeedback("");
    try {
      const result = await authenticatedFetch(path, {
        method: draft.id ? "PATCH" : "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data)
      });
      if (result.status === 401 || result.status === 403) { onAccessLost(); return; }
      if (result.status === 409) { setFeedback(messages.scheduleConflict); return; }
      if (result.status === 404) { setFeedback(messages.scheduleNotFound); return; }
      if (!result.ok) { setFeedback(messages.scheduleSaveError); return; }
      closeDraft();
      setFeedback(messages.scheduleSaved);
      await load(false);
    } catch { setFeedback(messages.scheduleSaveError); }
    finally { setBusy(false); }
  }

  async function saveDates(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft?.id || !dateDraft || !historySubject || !canEdit || busy) return;
    const start = parseBrazilianDate(dateDraft.plannedStart);
    const workingMode = dateDraft.planningMode === "working_days";
    const end = workingMode && previewMatches(workingPreview, dateDraft.plannedStart, dateDraft.workingDays)
      ? workingPreview.endDate : parseBrazilianDate(dateDraft.plannedEnd);
    const duration = Number(dateDraft.workingDays);
    if (!start || !end || start > end || (workingMode && (!/^\d+$/.test(dateDraft.workingDays) ||
        !Number.isSafeInteger(duration) || duration < 1 || duration > 27393 ||
        !previewMatches(workingPreview, dateDraft.plannedStart, dateDraft.workingDays)))) {
      setFeedback(workingMode ? messages.workingDayPreviewRequired : messages.dateChangeInvalid);
      return;
    }
    const originalStart = parseBrazilianDate(dateDraft.originalStart);
    const originalEnd = parseBrazilianDate(dateDraft.originalEnd);
    const dateChanged = start !== originalStart || end !== originalEnd;
    const planChanged = dateDraft.planningMode !== dateDraft.originalPlanningMode ||
      (workingMode && (duration !== dateDraft.originalWorkingDays ||
        workingPreview?.calendarVersion !== dateDraft.originalCalendarVersion));
    if (!dateChanged && !planChanged) {
      setFeedback(messages.dateChangeUnchanged); return;
    }
    const reason = dateDraft.reason.trim();
    if ((dateChanged || planChanged) && (reason.length < 10 || reason.length > 2000 ||
        Array.from(reason).some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127))) {
      setFeedback(messages.activityPlanReasonRequired); return;
    }
    setBusy(true);
    setFeedback("");
    try {
      const endpoint = `${base}/disciplines/${historySubject.disciplineId}/stages/${historySubject.stageId}/activities/${historySubject.id}`;
      const result = await authenticatedFetch(`${endpoint}/${workingMode ? "working-plan" : "dates"}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(workingMode
          ? { startDate: start, workingDays: duration, calendarVersion: workingPreview?.calendarVersion,
            reason, version: dateDraft.version }
          : { plannedStart: start, plannedEnd: end, reason: reason || null, version: dateDraft.version })
      });
      if (result.status === 401 || result.status === 403) { onAccessLost(); return; }
      if (result.status === 409) {
        const payload = await result.json().catch(() => null) as { code?: string } | null;
        setFeedback(payload?.code === "calendar_conflict" || payload?.code === "stale_calendar"
          ? messages.workingDayCalendarChanged : messages.scheduleConflict);
        return;
      }
      if (result.status === 404) { setFeedback(messages.scheduleNotFound); return; }
      if (result.status === 400) { setFeedback(messages.dateChangeInvalid); return; }
      if (!result.ok) { setFeedback(messages.scheduleSaveError); return; }
      const payload = await result.json() as { activity: Activity; changed: boolean };
      const updated = payload.activity;
      setDraft((previous) => previous ? { ...previous, plannedStart: formatCivilDate(updated.plannedStart),
        plannedEnd: formatCivilDate(updated.plannedEnd), version: updated.version } : null);
      setDateDraft({ originalStart: formatCivilDate(updated.plannedStart), originalEnd: formatCivilDate(updated.plannedEnd),
        plannedStart: updated.plannedStart ? formatCivilDate(updated.plannedStart) : "",
        plannedEnd: updated.plannedEnd ? formatCivilDate(updated.plannedEnd) : "", reason: "", version: updated.version,
        planningMode: updated.planningMode, workingDays: updated.workingDayDuration?.toString() ?? "",
        originalPlanningMode: updated.planningMode, originalWorkingDays: updated.workingDayDuration,
        originalCalendarVersion: updated.planningCalendarVersion });
      clearWorkingPreview();
      setFeedback(dateChanged ? messages.dateChangeSaved : messages.activityPlanSaved);
      await Promise.all([load(false), loadHistory(historySubject)]);
    } catch { setFeedback(messages.scheduleSaveError); }
    finally { setBusy(false); }
  }

  async function targetRequest(path: string, method: string, data?: unknown): Promise<Response> {
    let result: Response;
    try {
      result = await authenticatedFetch(path, { method, ...(data === undefined ? {} : {
        headers: { "Content-Type": "application/json" }, body: JSON.stringify(data)
      }) });
    } catch { throw new Error(messages.milestoneSaveError); }
    if (result.status === 401 || result.status === 403) {
      onAccessLost();
      throw new Error(messages.accessDenied);
    }
    return result;
  }
  async function createTarget(value: Omit<ScheduleTarget, "id" | "operationalDate" | "displayOrder" | "version">): Promise<ScheduleTarget> {
    const result = await targetRequest(`${base}/targets`, "POST", value);
    if (!result.ok) throw new Error((await result.json().catch(() => null))?.error ?? messages.milestoneSaveError);
    const target = (await result.json() as { target: ScheduleTarget }).target;
    setTargets((current) => [...current, target].sort((a, b) => a.displayOrder - b.displayOrder));
    return target;
  }
  async function updateTarget(target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }): Promise<ScheduleTarget> {
    const result = await targetRequest(`${base}/targets/${target.id}`, "PATCH", { ...value, version: target.version });
    if (!result.ok) throw new Error((await result.json().catch(() => null))?.error ?? messages.milestoneSaveError);
    const updated = (await result.json() as { target: ScheduleTarget }).target;
    setTargets((current) => current.map((item) => item.id === updated.id ? updated : item));
    return updated;
  }
  async function deleteTarget(target: ScheduleTarget): Promise<void> {
    const result = await targetRequest(`${base}/targets/${target.id}`, "DELETE", { version: target.version });
    if (!result.ok) throw new Error((await result.json().catch(() => null))?.error ?? messages.milestoneDeleteError);
    setTargets((current) => current.filter((item) => item.id !== target.id));
  }

  function changeDefinition(id: string) {
    const selected = definitions.find((definition) => definition.id === id);
    setDraft((previous) => previous ? { ...previous, definitionId: id,
      code: selected?.code ?? "", color: selected?.color ?? "#336699" } : null);
  }

  async function saveSharedStageColor() {
    if (!draft || draft.kind !== "stage" || draft.definitionId === newDefinition || !canEdit || busy) return;
    const definition = definitions.find((item) => item.id === draft.definitionId);
    if (!definition) { setFeedback(messages.sharedStageDefinitionMissing); return; }
    if (draft.color.toUpperCase() === definition.color.toUpperCase()) return;
    if (!window.confirm(messages.confirmSharedStageColor(definition.code))) return;
    setBusy(true);
    setFeedback("");
    try {
      const response = await authenticatedFetch(`/api/workspaces/${workspace.id}/stage-definitions/${definition.id}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ color: draft.color, expectedColor: definition.color })
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (response.status === 404) { setFeedback(messages.sharedStageDefinitionMissing); return; }
      if (response.status === 409) { setFeedback(messages.sharedStageColorConflict); return; }
      if (response.status === 400) { setFeedback(messages.hexadecimalColorHint); return; }
      if (!response.ok) { setFeedback(messages.sharedStageColorSaveError); return; }
      const payload = await response.json() as { stageDefinition: StageDefinition };
      setDefinitions((current) => current.map((item) => item.id === payload.stageDefinition.id
        ? payload.stageDefinition : item));
      setDraft((current) => current?.kind === "stage" ? { ...current, color: payload.stageDefinition.color } : current);
      await load(false);
      setFeedback(messages.sharedStageColorSaved);
    } catch { setFeedback(messages.sharedStageColorSaveError); }
    finally { setBusy(false); }
  }

  const selectedStageDefinition = draft?.kind === "stage"
    ? definitions.find((item) => item.id === draft.definitionId) : undefined;
  const sharedStageColorChanged = !!selectedStageDefinition && draft?.kind === "stage" &&
    draft.color.toUpperCase() !== selectedStageDefinition.color.toUpperCase();

  function editRow(row: VisibleRow) {
    const discipline = hierarchy?.disciplines.find((item) => item.id === row.disciplineId);
    if (!discipline) return;
    if (row.kind === "discipline") startDiscipline(discipline);
    if (row.kind === "stage") {
      const stage = discipline.stages.find((item) => item.id === row.id);
      if (stage) startStage(discipline.id, stage);
    }
    if (row.kind === "activity") {
      const stage = discipline.stages.find((item) => item.id === row.stageId);
      const activity = stage?.activities.find((item) => item.id === row.id);
      if (stage && activity) startActivity(discipline.id, stage.id, activity);
    }
  }

  function addChild(row: VisibleRow) {
    if (row.kind === "discipline") startStage(row.id);
    if (row.kind === "stage" && row.disciplineId) startActivity(row.disciplineId, row.id);
  }

  function openHistory(row: VisibleRow) {
    if (row.kind !== "activity" || !row.disciplineId || !row.stageId) return;
    rememberFocus();
    historyRequest.current++;
    setHistory([]);
    setHistoryState("loading");
    setDraft(null);
    setDateDraft(null);
    setFeedback("");
    setHistorySubject({ id: row.id, disciplineId: row.disciplineId, stageId: row.stageId, name: row.label });
  }

  const impactRows = useMemo(() => (impactData?.impacts ?? []).map((impact) => ({
    impact,
    activity: hierarchy?.disciplines.find((item) => item.id === impact.disciplineId)
      ?.stages.find((item) => item.id === impact.stageId)
      ?.activities.find((item) => item.id === impact.activityId)
  })), [impactData, hierarchy]);
  const impactStale = impactRows.some(({ impact, activity }) =>
    !activity || activity.planningMode !== "working_days" ||
    activity.version !== impact.activityVersion ||
    activity.plannedStart !== impact.currentStartDate ||
    activity.plannedEnd !== impact.currentEndDate ||
    activity.workingDayDuration !== impact.workingDays ||
    activity.planningCalendarVersion !== impact.savedCalendarVersion ||
    impact.currentCalendarVersion !== impactData?.calendarVersion);
  const visibleImpacts = useMemo(() => impactState === "ready" && !impactStale
    ? impactRows.map(({ impact }) => impact) : [], [impactRows, impactStale, impactState]);

  return (
    <section className="schedule-editor" aria-labelledby="schedule-title">
      <header className="schedule-titlebar">
        <button type="button" className="schedule-breadcrumb" aria-label={messages.backToProducts} onClick={onBack}>
          <span aria-hidden="true">‹</span> {messages.products}
        </button>
        <h2 id="schedule-title">{product.name}</h2>
      </header>
      {state === "loading" && <p role="status">{messages.scheduleLoading}</p>}
      {state === "notFound" && <p role="alert">{messages.scheduleNotFound}</p>}
      {state === "error" && <div role="alert"><p>{messages.scheduleLoadError}</p><button type="button" onClick={() => void load()}>{messages.retry}</button></div>}
      {state === "ready" && hierarchy && (
        <>
          {impactState === "loading" && <p className="calendar-impact-status" role="status">{messages.calendarImpactLoading}</p>}
          {impactState === "error" && <div className="calendar-impact-notice" role="alert">
            <span>{messages.calendarImpactError}</span>
            <button type="button" onClick={() => void refreshImpacts()}>{messages.retry}</button>
          </div>}
          {impactState === "ready" && impactStale && <div className="calendar-impact-notice" role="alert">
            <span>{messages.calendarImpactStale}</span>
            <button type="button" onClick={() => void load(false)}>{messages.refreshHierarchy}</button>
          </div>}
          {visibleImpacts.length > 0 && <div className="calendar-impact-notice" aria-live="polite">
            <span>{messages.calendarImpactNotice(visibleImpacts.length)}</span>
            <button type="button" onClick={(event) => {
              impactTriggerRef.current = event.currentTarget;
              setImpactOpen(true);
            }}>{messages.reviewCalendarImpacts}</button>
          </div>}
          {feedback && !draft && <div role="alert" className="feedback"><p>{feedback}</p></div>}
          {hierarchy.disciplines.length === 0 && <p>{messages.noDisciplines}</p>}
          <ScheduleWorkspace key={product.id} product={product} tree={hierarchy} targets={targets}
            calendarImpacts={impactOpen ? visibleImpacts : undefined}
            openDisciplines={openDisciplines ?? new Set()} openStages={openStages ?? new Set()}
            canEdit={canEdit} onToggle={(row) => {
              if (row.kind === "discipline" || row.kind === "stage") toggle(row.id, row.kind);
            }} onEdit={editRow} onAdd={addChild} onAddDiscipline={() => startDiscipline()}
            onRefresh={() => { closeDraft(); void load(false); }} onHistory={openHistory}
            onCreateTarget={createTarget} onUpdateTarget={updateTarget} onDeleteTarget={deleteTarget} />
        </>
      )}
      {impactOpen && state === "ready" && <aside ref={impactPanelRef} className="calendar-impact-panel"
        role="dialog" aria-labelledby="calendar-impact-title">
        <div className="calendar-impact-panel__header">
          <h3 id="calendar-impact-title">{messages.calendarImpactTitle}</h3>
          <button type="button" onClick={() => {
            setImpactOpen(false);
            queueMicrotask(() => impactTriggerRef.current?.focus());
          }}>{messages.calendarImpactLater}</button>
        </div>
        <p>{messages.calendarImpactReadOnly}</p>
        {impactState === "loading" && <p role="status">{messages.calendarImpactLoading}</p>}
        {impactState === "error" && <p role="alert">{messages.calendarImpactError}</p>}
        {impactState === "ready" && impactStale && <p role="alert">{messages.calendarImpactStale}</p>}
        {impactState === "ready" && !impactStale && <>
          <p className="calendar-impact-panel__version">{messages.calendarImpactSnapshot(impactData?.calendarVersion ?? 0)}</p>
          <ol className="calendar-impact-list">{impactRows.map(({ impact, activity }) => {
            const difference = dayNumber(impact.proposedEndDate) - dayNumber(impact.currentEndDate);
            return <li key={impact.activityId}>
              <h4>{activity?.name ?? messages.scheduleNotFound}</h4>
              <span className="calendar-impact-kind">{impact.impact === "date_change"
                ? messages.calendarImpactDateChange : messages.calendarImpactVersionOnly}</span>
              <p>{messages.calendarImpactCurrentEnd(formatCivilDate(impact.currentEndDate))}</p>
              <p>{messages.calendarImpactProposedEnd(formatCivilDate(impact.proposedEndDate))}</p>
              <p>{messages.calendarImpactDifference(difference)}</p>
              <p>{messages.calendarImpactVersions(impact.savedCalendarVersion, impact.currentCalendarVersion)}</p>
              {!impact.optionalDaysVerified && <p className="calendar-impact-warning" role="status">
                {messages.calendarImpactCoverageWarning(impact.unverifiedOptionalYears.join(", "))}
              </p>}
            </li>;
          })}</ol>
        </>}
        <button type="button" onClick={() => void (impactStale ? load(false) : refreshImpacts())}
          disabled={impactState === "loading"}>{messages.calendarImpactRefresh}</button>
      </aside>}
      {((draft && canEdit) || historySubject) && <div className="schedule-drawer-backdrop" onMouseDown={(event) => {
        if (event.target === event.currentTarget && !busy) closeDraft();
      }}><div ref={drawerRef} className="schedule-drawer" role="dialog" aria-modal="true"
        aria-labelledby="schedule-drawer-title">{draft && canEdit && <form className="hierarchy-form" onSubmit={(event) => void save(event)}>
        <h3 id="schedule-drawer-title">{draft.id ? (draft.kind === "discipline" ? messages.editDiscipline : draft.kind === "stage" ? messages.editStage : messages.editActivity) : messages.newItem}</h3>
        {draft.kind === "discipline" && <>
          <label htmlFor="hierarchy-name">{messages.disciplineName}</label>
          <input id="hierarchy-name" required maxLength={200} value={draft.name}
            onChange={(event) => setDraft({ ...draft, name: event.target.value })} />
          <label htmlFor="hierarchy-code">{messages.disciplineCode}</label>
          <input id="hierarchy-code" required maxLength={24} value={draft.shortCode}
            onChange={(event) => setDraft({ ...draft, shortCode: event.target.value })} />
          <ColorField id="hierarchy-color" label={messages.color} value={draft.color}
            onChange={(color) => setDraft({ ...draft, color })} />
          <label htmlFor="hierarchy-description">{messages.productDescription}</label>
          <textarea id="hierarchy-description" maxLength={2000} value={draft.description}
            onChange={(event) => setDraft({ ...draft, description: event.target.value })} />
        </>}
        {draft.kind === "stage" && <>
          <label htmlFor="stage-definition">{messages.stageDefinition}</label>
          <select id="stage-definition" value={draft.definitionId}
            onChange={(event) => changeDefinition(event.target.value)}>
            <option value={newDefinition}>{messages.newStageCode}</option>
            {definitions.map((definition) => <option key={definition.id} value={definition.id}>{definition.code}</option>)}
          </select>
          {draft.definitionId === newDefinition && <>
            <label htmlFor="stage-code">{messages.stageCode}</label>
            <input id="stage-code" required maxLength={24} value={draft.code}
              onChange={(event) => setDraft({ ...draft, code: event.target.value })} />
            <ColorField id="stage-color" label={messages.color} value={draft.color}
              onChange={(color) => setDraft({ ...draft, color })} />
          </>}
          {draft.definitionId !== newDefinition && <>
            <ColorField id="shared-stage-color" label={messages.color} value={draft.color}
              onChange={(color) => setDraft({ ...draft, color })} />
            <p>{messages.sharedStageColor(draft.code)}</p>
            {sharedStageColorChanged && <div className="schedule-toolbar">
              <button type="button" onClick={() => void saveSharedStageColor()} disabled={busy}>
                {messages.saveSharedStageColor}
              </button>
            </div>}
          </>}
          <label htmlFor="stage-name">{messages.stageName}</label>
          <input id="stage-name" required maxLength={200} value={draft.displayName}
            onChange={(event) => setDraft({ ...draft, displayName: event.target.value })} />
        </>}
        {draft.kind === "activity" && <>
          <label htmlFor="activity-name">{messages.activityName}</label>
          <input id="activity-name" required maxLength={300} value={draft.name}
            onChange={(event) => setDraft({ ...draft, name: event.target.value })} />
          <label htmlFor="activity-type">{messages.activityType}</label>
          <input id="activity-type" maxLength={80} value={draft.activityType}
            onChange={(event) => setDraft({ ...draft, activityType: event.target.value })} />
          {draft.id ? <p>{messages.existingDates}: {messages.dateRange(draft.plannedStart, draft.plannedEnd)}</p>
            : <>
              <label htmlFor="activity-planning-mode">{messages.activityPlanningMode}</label>
              <select id="activity-planning-mode" value={draft.planningMode} onChange={(event) => {
                clearWorkingPreview();
                setDraft({ ...draft, planningMode: event.target.value as Draft["planningMode"] });
              }}>
                <option value="manual">{messages.manualPlanning}</option>
                <option value="working_days">{messages.workingDaysPlanning}</option>
              </select>
              <label htmlFor="activity-start">{messages.plannedStart}</label>
              <input id="activity-start" inputMode="numeric" placeholder="DD/MM/AAAA" value={draft.plannedStart}
                onChange={(event) => { clearWorkingPreview(); setDraft({ ...draft, plannedStart: event.target.value }); }} />
              {draft.planningMode === "manual" ? <>
                <label htmlFor="activity-end">{messages.plannedEnd}</label>
                <input id="activity-end" inputMode="numeric" placeholder="DD/MM/AAAA" value={draft.plannedEnd}
                  onChange={(event) => setDraft({ ...draft, plannedEnd: event.target.value })} />
              </> : <>
                <label htmlFor="activity-working-days">{messages.workingDayDuration}</label>
                <input id="activity-working-days" type="number" min={1} max={27393} step={1}
                  value={draft.workingDays} onChange={(event) => {
                    clearWorkingPreview(); setDraft({ ...draft, workingDays: event.target.value });
                  }} />
                <button type="button" onClick={() => void calculateWorkingPreview(draft.plannedStart, draft.workingDays)}
                  disabled={previewLoading || busy}>{messages.calculateWorkingEnd}</button>
                <WorkingPreviewDetails preview={workingPreview} loading={previewLoading} />
              </>}
            </>}
          <label htmlFor="activity-notes">{messages.activityNotes}</label>
          <textarea id="activity-notes" maxLength={4000} value={draft.notes}
            onChange={(event) => setDraft({ ...draft, notes: event.target.value })} />
        </>}
        <label htmlFor="hierarchy-order">{messages.displayOrder}</label>
        <input id="hierarchy-order" type="number" min={0} max={1000000} required value={draft.displayOrder}
          onChange={(event) => setDraft({ ...draft, displayOrder: event.target.value })} />
        <footer className="schedule-drawer__footer">
          <button type="submit" disabled={busy}>{draft.kind === "activity" && draft.id ? messages.saveActivityDetails : messages.save}</button>
          <button type="button" className="back-button" onClick={closeDraft} disabled={busy}>{messages.cancel}</button>
        </footer>
      </form>}
      {draft?.kind === "activity" && draft.id && dateDraft && canEdit && <form className="schedule-date-form"
        onSubmit={(event) => void saveDates(event)}>
        <h4>{messages.proposedDates}</h4>
        <p>{messages.originalDates}: {messages.dateRange(dateDraft.originalStart, dateDraft.originalEnd)}</p>
        <p>{messages.dateChangesLater}</p>
        <label htmlFor="date-planning-mode">{messages.activityPlanningMode}</label>
        <select id="date-planning-mode" value={dateDraft.planningMode} onChange={(event) => {
          clearWorkingPreview();
          setDateDraft({ ...dateDraft, planningMode: event.target.value as DateDraft["planningMode"] });
        }}>
          <option value="manual">{messages.manualPlanning}</option>
          <option value="working_days">{messages.workingDaysPlanning}</option>
        </select>
        <label htmlFor="date-start">{messages.plannedStart}</label>
        <input id="date-start" inputMode="numeric" placeholder="DD/MM/AAAA" value={dateDraft.plannedStart}
          onChange={(event) => { clearWorkingPreview(); setDateDraft({ ...dateDraft, plannedStart: event.target.value }); }} />
        {dateDraft.planningMode === "manual" ? <>
          <label htmlFor="date-end">{messages.plannedEnd}</label>
          <input id="date-end" inputMode="numeric" placeholder="DD/MM/AAAA" value={dateDraft.plannedEnd}
            onChange={(event) => setDateDraft({ ...dateDraft, plannedEnd: event.target.value })} />
        </> : <>
          <label htmlFor="date-working-days">{messages.workingDayDuration}</label>
          <input id="date-working-days" type="number" min={1} max={27393} step={1}
            value={dateDraft.workingDays} onChange={(event) => {
              clearWorkingPreview(); setDateDraft({ ...dateDraft, workingDays: event.target.value });
            }} />
          <button type="button" onClick={() => void calculateWorkingPreview(dateDraft.plannedStart, dateDraft.workingDays)}
            disabled={previewLoading || busy}>{messages.calculateWorkingEnd}</button>
          <WorkingPreviewDetails preview={workingPreview} loading={previewLoading} />
        </>}
        <label htmlFor="date-reason">{messages.dateChangeReason}</label>
        <textarea id="date-reason" maxLength={2000} value={dateDraft.reason}
          onChange={(event) => setDateDraft({ ...dateDraft, reason: event.target.value })} />
        <footer className="schedule-drawer__footer">
          <button type="submit" disabled={busy}>{messages.saveActivityDates}</button>
          <button type="button" className="back-button" onClick={() => {
            setDateDraft((previous) => previous ? { ...previous,
              plannedStart: previous.originalStart === messages.noDate ? "" : previous.originalStart,
              plannedEnd: previous.originalEnd === messages.noDate ? "" : previous.originalEnd, reason: "" } : null);
            setFeedback("");
          }} disabled={busy}>{messages.cancel}</button>
        </footer>
      </form>}
      {feedback && <div role="alert" className="feedback"><p>{feedback}</p>
        {feedback === messages.scheduleConflict && <button type="button" onClick={() => { closeDraft(); void load(false); }}>{messages.refreshHierarchy}</button>}
      </div>}
      {historySubject && <section className="schedule-history" aria-label={messages.activityDateHistory}>
        {!draft && <h3 id="schedule-drawer-title">{messages.activityDateHistory}: {historySubject.name}</h3>}
        {draft && <h4>{messages.activityDateHistory}</h4>}
        {historyState === "loading" && <p role="status">{messages.historyLoading}</p>}
        {historyState === "error" && <div role="alert"><p>{messages.historyError}</p>
          <button type="button" onClick={() => void loadHistory(historySubject)}>{messages.retry}</button></div>}
        {historyState === "ready" && (history.length === 0 ? <p>{messages.historyEmpty}</p> :
          <ol>{history.map((change) => <li key={change.operationId}>
            <time dateTime={change.changedAt}>{auditDate.format(new Date(change.changedAt))}</time>
            <p>{messages.historyEntry(messages.dateRange(formatCivilDate(change.previousStart), formatCivilDate(change.previousEnd)),
              messages.dateRange(formatCivilDate(change.newStart), formatCivilDate(change.newEnd)))}</p>
            <p>{change.reason}</p>
          </li>)}</ol>)}
        {!draft && <button type="button" className="back-button" onClick={closeDraft}>{messages.closeHistory}</button>}
      </section>}
      </div></div>}
    </section>
  );
}
