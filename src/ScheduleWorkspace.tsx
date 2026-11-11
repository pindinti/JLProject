import { type CSSProperties, type FormEvent, type MouseEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { civilFromDay, dayNumber, makeTimeline, saoPauloCivilDate, timelineDateAtPosition,
  timelineInterval, timelinePosition, visibleScheduleRows,
  type ScheduleTarget, type ScheduleTree, type VisibleRow, type Zoom } from "../domain/schedule-workspace";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { messages } from "./locales/pt-BR";
import { ColorField } from "./ColorField";
import { layoutMilestoneLabels } from "./design/gantt-colors";
import { rememberRecentCustomColor } from "./recent-color-history";
import type { ActivityCalendarImpact } from "../domain/calendar-impact";
import { nonWorkingDayRanges } from "../domain/non-working-day-ranges";
import { parseCivilDate, type CalendarExceptionDates } from "../domain/working-calendar";
import { authenticatedFetch } from "./auth";

const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
const noCalendarImpacts: ActivityCalendarImpact[] = [];
type CalendarYearSnapshot = { version: number; exceptions: CalendarExceptionDates[] };
type DeletionTarget = { kind: "discipline" | "stage" | "activity"; id: string; label: string };

export function ScheduleWorkspace({ product, tree, targets, workspaceId, openDisciplines, openStages,
  canEdit, calendarImpacts = noCalendarImpacts, onToggle, onEdit, onAdd, onAddDiscipline,
  onAddRootActivity,
  onRefresh, onHistory, onProductHistory, onRescheduleHistory, onCreateTarget, onUpdateTarget, onDeleteTarget,
  userId, onAccessLost = () => undefined }: {
  product: { id: string; name: string }; tree: ScheduleTree; targets: ScheduleTarget[]; workspaceId?: string;
  userId?: string | null;
  openDisciplines: ReadonlySet<string>; openStages: ReadonlySet<string>; canEdit: boolean;
  calendarImpacts?: ActivityCalendarImpact[];
  onToggle: (row: VisibleRow) => void; onEdit: (row: VisibleRow) => void;
  onAdd: (row: VisibleRow) => void; onHistory: (row: VisibleRow) => void;
  onAddDiscipline: () => void; onAddRootActivity?: () => void;
  onRefresh: () => void | Promise<void>; onProductHistory: () => void;
  onRescheduleHistory: () => void;
  onCreateTarget: (value: { name: string; description: string | null; targetDate: string; color: string }) => Promise<ScheduleTarget>;
  onUpdateTarget: (target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }) => Promise<ScheduleTarget>;
  onDeleteTarget: (target: ScheduleTarget) => Promise<void>;
  onAccessLost?: () => void;
}) {
  const [zoom, setZoom] = useState<Zoom>("week");
  const [tableWidth, setTableWidth] = useState(50);
  const [selected, setSelected] = useState<string | null>(null);
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const [today, setToday] = useState(() => saoPauloCivilDate(new Date()));
  const [bounds, setBounds] = useState(() => {
    const initial = makeTimeline(tree, targets, "week", today);
    return { startDay: initial.startDay, endDay: initial.endDay };
  });
  const [productExpanded, setProductExpanded] = useState(true);
  const [mobilePane, setMobilePane] = useState<"table" | "gantt">("table");
  const [targetDialog, setTargetDialog] = useState<ScheduleTarget | "new" | null>(null);
  const [deletionTarget, setDeletionTarget] = useState<DeletionTarget | null>(null);
  const [deletionPreview, setDeletionPreview] = useState<{ fingerprint: string;
    counts: { disciplines: number; stages: number; activities: number } } | null>(null);
  const [deletionReason, setDeletionReason] = useState("");
  const [deletionError, setDeletionError] = useState("");
  const [deletionLoading, setDeletionLoading] = useState(false);
  const [deletionBusy, setDeletionBusy] = useState(false);
  const [deletionStale, setDeletionStale] = useState(false);
  const deletionSubmitting = useRef(false);
  const deletionRequest = useRef(0);
  const deletionTrigger = useRef<HTMLButtonElement | null>(null);
  const deletionDialog = useRef<HTMLDivElement>(null);
  const [calendarExceptionsByYear, setCalendarExceptionsByYear] = useState<Record<number, CalendarYearSnapshot | null>>({});
  const splitRef = useRef<HTMLDivElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<HTMLDivElement>(null);
  const scrollbarRef = useRef<HTMLDivElement>(null);
  const centerDateAfterScale = useRef<string | null>(null);
  const dragging = useRef(false);
  const rows = useMemo(() => visibleScheduleRows(product, tree, openDisciplines, openStages, productExpanded),
    [product, tree, openDisciplines, openStages, productExpanded]);
  const scale = useMemo(() => {
    const previewBounds = { ...bounds };
    for (const impact of calendarImpacts) {
      if (impact.impact !== "date_change") continue;
      previewBounds.startDay = Math.min(previewBounds.startDay, dayNumber(impact.proposedStartDate) - 14);
      previewBounds.endDay = Math.max(previewBounds.endDay, dayNumber(impact.proposedEndDate) + 14);
    }
    return makeTimeline(tree, targets, zoom, today, previewBounds);
  }, [tree, targets, zoom, today, bounds, calendarImpacts]);
  const calendarYears = useMemo(() => {
    const first = parseCivilDate(civilFromDay(scale.startDay))?.year;
    const last = parseCivilDate(civilFromDay(scale.endDay))?.year;
    if (first === undefined || last === undefined) return [];
    return Array.from({ length: last - first + 1 }, (_, index) => first + index)
      .filter((year) => year >= 2026 && year <= 2100);
  }, [scale.startDay, scale.endDay]);
  const calendarYearKey = calendarYears.join(",");
  useEffect(() => {
    if (!workspaceId || !calendarYearKey) return;
    const years = calendarYearKey.split(",").map(Number).filter((year) => !(year in calendarExceptionsByYear));
    if (years.length === 0) return;
    let active = true;
    void Promise.all(years.map(async (year): Promise<[number, CalendarYearSnapshot | null]> => {
      try {
        const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/calendar?year=${year}`);
        if (!response.ok) return [year, null];
        const payload = await response.json() as { calendar?: { version?: unknown; exceptions?: unknown } };
        if (!Number.isSafeInteger(payload.calendar?.version) || !Array.isArray(payload.calendar?.exceptions)) return [year, null];
        const exceptions = payload.calendar.exceptions.filter((item): item is CalendarExceptionDates => {
          if (!item || typeof item !== "object") return false;
          const candidate = item as Partial<CalendarExceptionDates>;
          return ["municipal_holiday", "collective_vacation", "company_shutdown"].includes(candidate.kind ?? "") &&
            typeof candidate.startDate === "string" && !!parseCivilDate(candidate.startDate) &&
            typeof candidate.endDate === "string" && !!parseCivilDate(candidate.endDate) &&
            candidate.startDate <= candidate.endDate;
        });
        return [year, { version: Number(payload.calendar?.version), exceptions }];
      } catch { return [year, null]; }
    })).then((results) => {
      if (active) setCalendarExceptionsByYear((current) => ({ ...current, ...Object.fromEntries(results) }));
    });
    return () => { active = false; };
  }, [workspaceId, calendarYearKey, calendarExceptionsByYear]);
  const calendarExceptions = useMemo(() => calendarYears.flatMap((year) => calendarExceptionsByYear[year]?.exceptions ?? []),
    [calendarYears, calendarExceptionsByYear]);
  const calendarLoading = !!workspaceId && calendarYears.some((year) => !(year in calendarExceptionsByYear));
  const calendarVersions = new Set(calendarYears.map((year) => calendarExceptionsByYear[year]?.version)
    .filter((version): version is number => version !== undefined));
  const calendarFailed = !!workspaceId && (calendarYears.some((year) => calendarExceptionsByYear[year] === null) || calendarVersions.size > 1);
  const nonWorkingRanges = useMemo(() => nonWorkingDayRanges(scale.startDay, scale.endDay, calendarExceptions),
    [scale.startDay, scale.endDay, calendarExceptions]);
  const impactByActivity = useMemo(() => new Map(calendarImpacts.filter((impact) =>
    impact.impact === "date_change").map((impact) => [impact.activityId, impact])), [calendarImpacts]);
  const milestoneLabels = useMemo(() => layoutMilestoneLabels(targets,
    (date) => timelinePosition(scale, date), scale.width), [targets, scale]);
  const milestoneLaneCount = milestoneLabels.reduce((count, label) => Math.max(count, label.lane + 1), 0);
  const targetHeadHeight = Math.max(29, milestoneLaneCount * 18 + 22);
  const headerHeight = Math.max(82, 28 + 24 + targetHeadHeight);

  async function fetchDeletionPreview(target: DeletionTarget,
    resetReason: boolean) {
    const requestId = ++deletionRequest.current;
    if (resetReason) setDeletionReason("");
    setDeletionPreview(null);
    setDeletionStale(false);
    setDeletionError("");
    setDeletionLoading(true);
    if (!workspaceId) {
      setDeletionError(messages.scheduleDeletionPreviewError);
      setDeletionLoading(false);
      return;
    }
    const query = new URLSearchParams({ kind: target.kind, targetId: target.id });
    try {
      const result = await authenticatedFetch(`/api/workspaces/${workspaceId}/products/${product.id}/hierarchy/deletion-preview?${query}`);
      if (requestId !== deletionRequest.current) return;
      if (result.status === 401 || result.status === 403) {
        onAccessLost();
        setDeletionError(messages.scheduleDeletionPermissionError);
        return;
      }
      if (result.status === 404) {
        setDeletionError(messages.scheduleDeletionNotFound);
        return;
      }
      if (!result.ok) throw new Error("Deletion preview failed.");
      const value = await result.json() as { fingerprint?: unknown;
        counts?: Partial<{ disciplines: number; stages: number; activities: number }> };
      if (typeof value.fingerprint !== "string" || !/^[0-9a-f]{32}$/.test(value.fingerprint) ||
          !value.counts || ![value.counts.disciplines, value.counts.stages, value.counts.activities]
            .every((count) => Number.isSafeInteger(count) && Number(count) >= 0))
        throw new Error("Invalid deletion preview.");
      setDeletionPreview({ fingerprint: value.fingerprint, counts: {
        disciplines: Number(value.counts.disciplines), stages: Number(value.counts.stages),
        activities: Number(value.counts.activities)
      } });
    } catch {
      if (requestId === deletionRequest.current) setDeletionError(messages.scheduleDeletionPreviewError);
    } finally {
      if (requestId === deletionRequest.current) setDeletionLoading(false);
    }
  }

  function startDeletion(row: VisibleRow, trigger: HTMLButtonElement) {
    if (!canEdit || row.kind === "product" || deletionBusy) return;
    deletionTrigger.current = trigger;
    const target: DeletionTarget = { kind: row.kind, id: row.id, label: row.label };
    setDeletionTarget(target);
    void fetchDeletionPreview(target, true);
  }

  async function confirmDeletion(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canEdit || !deletionTarget || !deletionPreview || deletionStale || deletionSubmitting.current) return;
    const reason = deletionReason.trim();
    if (reason.length < 10) {
      setDeletionError(messages.scheduleDeletionReasonHint);
      return;
    }
    deletionSubmitting.current = true;
    setDeletionBusy(true);
    setDeletionError("");
    try {
      const result = await authenticatedFetch(`/api/workspaces/${workspaceId}/products/${product.id}/hierarchy/deletions`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ kind: deletionTarget.kind, targetId: deletionTarget.id,
          fingerprint: deletionPreview.fingerprint, reason })
      });
      if (result.status === 401 || result.status === 403) {
        onAccessLost();
        setDeletionError(messages.scheduleDeletionPermissionError);
        return;
      }
      if (result.status === 404) {
        setDeletionError(messages.scheduleDeletionNotFound);
        return;
      }
      if (result.status === 409) {
        setDeletionStale(true);
        setDeletionError(messages.scheduleDeletionConflict);
        return;
      }
      if (result.status === 400) {
        setDeletionError(messages.scheduleDeletionInvalid);
        return;
      }
      if (!result.ok) throw new Error("Deletion request failed.");
      setDeletionTarget(null);
      setDeletionPreview(null);
      setSelected(null);
      await onRefresh();
      document.querySelector<HTMLElement>(".workspace-table-rows")?.focus();
    } catch {
      setDeletionError(messages.scheduleDeletionSaveError);
    } finally {
      deletionSubmitting.current = false;
      setDeletionBusy(false);
    }
  }

  useEffect(() => {
    if (!deletionTarget) return;
    const dismiss = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !deletionSubmitting.current) {
        event.preventDefault();
        deletionRequest.current++;
        setDeletionTarget(null);
        setDeletionPreview(null);
        queueMicrotask(() => deletionTrigger.current?.focus());
      }
    };
    document.addEventListener("keydown", dismiss);
    return () => document.removeEventListener("keydown", dismiss);
  }, [deletionTarget]);

  useEffect(() => {
    if (deletionTarget) deletionDialog.current?.querySelector<HTMLElement>("button, textarea")?.focus();
  }, [deletionTarget, deletionLoading, deletionPreview]);

  useEffect(() => {
    if (scale.startDay !== bounds.startDay || scale.endDay !== bounds.endDay)
      queueMicrotask(() => setBounds({ startDay: scale.startDay, endDay: scale.endDay }));
  }, [scale.startDay, scale.endDay, bounds.startDay, bounds.endDay]);

  useEffect(() => {
    const refresh = () => setToday(saoPauloCivilDate(new Date()));
    const timer = window.setInterval(refresh, 30_000);
    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", refresh);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, []);

  useLayoutEffect(() => {
    const date = centerDateAfterScale.current;
    const scrollbar = scrollbarRef.current;
    const chart = chartRef.current;
    if (date && scrollbar && chart) {
      const viewportWidth = chart.clientWidth || scrollbar.clientWidth;
      const desiredPosition = timelinePosition(scale, date) + scale.dayWidth / 2 - viewportWidth / 2;
      scrollbar.scrollLeft = Math.max(0, Math.min(scrollbar.scrollWidth - scrollbar.clientWidth, desiredPosition));
      centerDateAfterScale.current = null;
    }
    const position = scrollbar?.scrollLeft ?? 0;
    if (headerRef.current) headerRef.current.scrollLeft = position;
    if (chart) chart.scrollLeft = position;
  }, [scale, tableWidth]);

  useEffect(() => {
    const move = (event: PointerEvent) => {
      if (!dragging.current || !splitRef.current) return;
      const box = splitRef.current.getBoundingClientRect();
      setTableWidth(Math.min(70, Math.max(30, Math.round((event.clientX - box.left) / box.width * 100))));
    };
    const stop = () => { dragging.current = false; };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", stop);
    return () => { window.removeEventListener("pointermove", move); window.removeEventListener("pointerup", stop); };
  }, []);

  function syncScroll(source: "header" | "chart" | "scrollbar") {
    const elements = { header: headerRef.current, chart: chartRef.current, scrollbar: scrollbarRef.current };
    const position = elements[source]?.scrollLeft;
    if (position === undefined) return;
    for (const element of Object.values(elements)) {
      if (element && element.scrollLeft !== position) element.scrollLeft = position;
    }
  }

  function shiftTimeline(direction: -1 | 1) {
    if (!scrollbarRef.current) return;
    scrollbarRef.current.scrollLeft += direction * 300;
    syncScroll("scrollbar");
  }

  function scrollTimelineToDate(date: string, timeline: typeof scale) {
    const scrollbar = scrollbarRef.current;
    const chart = chartRef.current;
    if (!scrollbar || !chart) return;
    const viewportWidth = chart.clientWidth || scrollbar.clientWidth;
    const desiredPosition = timelinePosition(timeline, date) + timeline.dayWidth / 2 - viewportWidth / 2;
    scrollbar.scrollLeft = Math.max(0, Math.min(scrollbar.scrollWidth - scrollbar.clientWidth, desiredPosition));
    syncScroll("scrollbar");
  }

  function goToToday() {
    const date = saoPauloCivilDate(new Date());
    setToday(date);
    setSelectedDate(date);
    const chart = chartRef.current;
    const scrollbar = scrollbarRef.current;
    if (!chart || !scrollbar) return;
    const viewportWidth = chart.clientWidth || scrollbar.clientWidth;
    if (viewportWidth > 0) {
      const halfVisibleDays = Math.ceil(viewportWidth / (2 * scale.dayWidth));
      const todayDay = dayNumber(date);
      const nextBounds = {
        startDay: Math.min(bounds.startDay, todayDay - halfVisibleDays),
        endDay: Math.max(bounds.endDay, todayDay + halfVisibleDays)
      };
      if (nextBounds.startDay !== bounds.startDay || nextBounds.endDay !== bounds.endDay) {
        centerDateAfterScale.current = date;
        setBounds(nextBounds);
        return;
      }
    }
    scrollTimelineToDate(date, scale);
  }

  function selectDate(event: MouseEvent<HTMLDivElement>) {
    const element = event.currentTarget;
    const position = event.clientX - element.getBoundingClientRect().left + element.scrollLeft;
    setSelectedDate(timelineDateAtPosition(scale, position));
  }

  function changeSelectedDate(direction: -1 | 1) {
    const day = dayNumber(selectedDate ?? today) + direction;
    setSelectedDate(civilFromDay(Math.max(scale.startDay, Math.min(scale.endDay, day))));
  }

  const style = { "--table-width": `${tableWidth}%` } as CSSProperties;
  return <section className="schedule-workspace" data-density="compact" aria-label={messages.scheduleWorkspace}>
    <div className="workspace-controls">
      <div className="workspace-toolbar-actions">
        {canEdit && <button type="button" onClick={onAddDiscipline}>{messages.addDiscipline}</button>}
        <button type="button" onClick={() => { setCalendarExceptionsByYear({}); onRefresh(); }}>{messages.refreshHierarchy}</button>
        <button type="button" onClick={onProductHistory}>{messages.productHistoryOpen}</button>
        <button type="button" onClick={onRescheduleHistory}>{messages.calendarRescheduleHistory}</button>
      </div>
      <div className="workspace-zoom" role="group" aria-label={messages.scheduleZoom}>
        {([ ["day", messages.zoomDay], ["week", messages.zoomWeek], ["month", messages.zoomMonth] ] as const).map(([value, label]) =>
          <button key={value} type="button" aria-pressed={zoom === value}
            onClick={() => setZoom(value)}>{label}</button>)}
      </div>
      <div className="workspace-timeline-navigation" role="group" aria-label={messages.scheduleTimeline}>
        <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(-1)}>{messages.timelineEarlier}</button>
        <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(1)}>{messages.timelineLater}</button>
        <button type="button" className="timeline-navigation" aria-label={messages.goToToday}
          title={messages.goToToday} onClick={goToToday}>{messages.today}</button>
      </div>
      {calendarLoading && <span className="calendar-highlight-status" role="status">{messages.calendarHighlightLoading}</span>}
      {calendarFailed && <span className="calendar-highlight-status" role="status">
        {messages.calendarHighlightError}{" "}
        <button type="button" onClick={() => setCalendarExceptionsByYear((current) => {
          const next = { ...current };
          for (const year of calendarYears) delete next[year];
          return next;
        })}>{messages.calendarHighlightRetry}</button>
      </span>}
      {selectedDate && <span role="status" className="workspace-selected-date">
        {messages.selectedDate(formatCivilDate(selectedDate))}
        <button type="button" onClick={() => setSelectedDate(null)}>{messages.clearSelectedDate}</button>
      </span>}
      {canEdit && <button type="button" onClick={() => setTargetDialog("new")}>{messages.addMilestone}</button>}
      <span>{messages.targetCount(targets.length)}</span>
      <div className="workspace-mobile-switch" role="group" aria-label={messages.schedulePane}>
        <button type="button" aria-pressed={mobilePane === "table"} onClick={() => setMobilePane("table")}>{messages.scheduleTable}</button>
        <button type="button" aria-pressed={mobilePane === "gantt"} onClick={() => setMobilePane("gantt")}>{messages.scheduleGantt}</button>
      </div>
    </div>
    <div ref={splitRef} className={`workspace-split mobile-${mobilePane}`} style={style}>
      <div className="workspace-headers" style={{ height: headerHeight, flexBasis: headerHeight }}>
        <div className="workspace-table-header" style={{ height: headerHeight }}>
          <span>{messages.scheduleItem}</span><span>{messages.plannedStart}</span>
          <span>{messages.plannedEnd}</span>
        </div>
        <div className="workspace-divider-header" />
        <div ref={headerRef} className="workspace-timeline-header" onScroll={() => syncScroll("header")}
          onClick={selectDate} onKeyDown={(event) => {
            if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
              event.preventDefault();
              changeSelectedDate(event.key === "ArrowLeft" ? -1 : 1);
            }
          }} tabIndex={0} role="group" aria-label={messages.timelineDateInstructions}>
          <div className="timeline-head-content" style={{ width: scale.width, height: headerHeight }}>
            <div className="timeline-months">{scale.months.map((month) => <div key={month.startDay}
              className="timeline-month" style={{ width: month.days * scale.dayWidth }}>
              {monthLabel.format(new Date(month.startDay * 86_400_000))}
            </div>)}</div>
            <div className="timeline-ticks">{scale.ticks.map((day) => <span key={day} className="timeline-tick"
              style={{ left: (day - scale.startDay) * scale.dayWidth }}>
              {zoom === "month" ? formatCivilDate(civilFromDay(day)).slice(3) : formatCivilDate(civilFromDay(day)).slice(0, 5)}
            </span>)}</div>
            <div className="timeline-target-head" style={{ height: targetHeadHeight }}>
              {milestoneLabels.map((label) => {
                const target = targets.find((item) => item.id === label.id);
                if (!target) return null;
                return <button type="button" key={target.id} className="timeline-target-label"
                  style={{ left: label.left, top: 2 + label.lane * 18, width: label.width, color: target.color }}
                  title={messages.targetDetail(target.name, formatCivilDate(target.targetDate))}
                  aria-label={`${messages.targetDetail(target.name, formatCivilDate(target.targetDate))}. ${canEdit ? messages.edit : messages.milestoneView}`}
                  onClick={(event) => { event.stopPropagation(); setTargetDialog(target); }}>
                  {label.name}
                </button>;
              })}
              <span className="timeline-today-label" style={{ left: timelinePosition(scale, today), top: targetHeadHeight - 17 }}
                title={`${messages.today}: ${formatCivilDate(today)}`}>{messages.today}</span>
            </div>
          </div>
        </div>
      </div>
      <div className="workspace-body">
        <div className="workspace-table-rows" role="table" aria-label={messages.scheduleTable} tabIndex={-1}>
          {rows.map((row) => <div key={row.key} className={`workspace-table-row row-${row.kind}${selected === row.key ? " selected" : ""}`}
            data-row-key={row.key} role="row" aria-selected={selected === row.key}>
            <div role="cell" className="workspace-name-cell" style={{ paddingLeft: `${
              row.kind === "activity" && !row.disciplineId ? 12
                : ({ product: 0, discipline: 12, stage: 27, activity: 42 })[row.kind]
            }px` }}>
              {row.hasChildren && <button type="button" className="workspace-expand" aria-expanded={row.expanded}
                aria-label={messages.toggleScheduleRow(row.label)} onClick={() => {
                  if (row.kind === "product") setProductExpanded((value) => !value);
                  else onToggle(row);
                }}>
                {row.expanded ? "▾" : "▸"}
              </button>}
              {!row.hasChildren && <span className="workspace-expand-spacer" />}
              {row.color && <span className="color-chip" style={{ backgroundColor: row.color }}
                aria-label={messages.scheduleColor(row.color)} />}
              <span className="workspace-inline-actions">
                {canEdit && row.kind === "product" && onAddRootActivity && <button type="button" className="workspace-icon-action"
                  aria-label={messages.addActivity} title={messages.addActivity}
                  onClick={() => { setSelected(row.key); onAddRootActivity(); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M10 3v14M3 10h14" /></svg>
                </button>}
                {canEdit && row.kind !== "product" && <button type="button" className="workspace-icon-action"
                  aria-label={row.kind === "discipline" ? messages.editDiscipline : row.kind === "stage" ? messages.editStage : messages.editActivity}
                  title={row.kind === "discipline" ? messages.editDiscipline : row.kind === "stage" ? messages.editStage : messages.editActivity}
                  onClick={() => { setSelected(row.key); onEdit(row); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="m13.8 3.2 3 3-9.9 9.9-3.6.7.7-3.6 9.8-10Z" /><path d="m11.9 5.1 3 3M3.5 16.5l3.6-.7" /></svg>
                </button>}
                {canEdit && (row.kind === "discipline" || row.kind === "stage") && <button type="button" className="workspace-icon-action"
                  aria-label={row.kind === "discipline" ? messages.addStage : messages.addActivity}
                  title={row.kind === "discipline" ? messages.addStage : messages.addActivity}
                  onClick={() => { setSelected(row.key); onAdd(row); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M10 3v14M3 10h14" /></svg>
                </button>}
                {canEdit && row.kind !== "product" && <button type="button" className="workspace-icon-action workspace-icon-action--delete"
                  aria-label={`${messages.deleteScheduleItem(row.kind)}: ${row.label}`}
                  title={`${messages.deleteScheduleItem(row.kind)}: ${row.label}`}
                  onClick={(event) => { setSelected(row.key); startDeletion(row, event.currentTarget); }}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M4 6h12m-10 0 .7 10h6.6L14 6M8 6V4h4v2m-3 3v4m2-4v4" /></svg>
                </button>}
                {row.kind === "activity" && <button type="button" className="workspace-icon-action"
                  title={messages.activityDateHistoryFor(row.label)} onClick={() => { setSelected(row.key); onHistory(row); }}
                  aria-label={messages.activityDateHistoryFor(row.label)}>
                  <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><path d="M3 4.5h14v12H3zM6 2.5v4M14 2.5v4M3 8h14M6 11h2m2 0h2m-6 3h2" /></svg>
                </button>}
              </span>
              <button type="button" className="workspace-row-name" title={row.label}
                onClick={() => setSelected(row.key)}
                onDoubleClick={() => { if (canEdit) { setSelected(row.key); onEdit(row); } }}>
                {row.label}{row.code ? ` (${row.code})` : ""}
              </button>
            </div>
            <span role="cell" className="workspace-date-cell" onDoubleClick={() => {
              if (canEdit) { setSelected(row.key); onEdit(row); }
            }}>{formatCivilDate(row.start)}</span>
            <span role="cell" className="workspace-date-cell" onDoubleClick={() => {
              if (canEdit) { setSelected(row.key); onEdit(row); }
            }}>{formatCivilDate(row.end)}</span>
          </div>)}
        </div>
        <div className="workspace-divider" role="separator" tabIndex={0} aria-orientation="vertical"
          aria-label={messages.resizeSchedulePanes} aria-valuemin={30} aria-valuemax={70} aria-valuenow={tableWidth}
          onPointerDown={() => { dragging.current = true; }} onKeyDown={(event) => {
            if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
              event.preventDefault();
              setTableWidth((value) => Math.min(70, Math.max(30, value + (event.key === "ArrowRight" ? 5 : -5))));
            }
          }} />
        <div ref={chartRef} className="workspace-chart-scroll" onScroll={() => syncScroll("chart")}
          onClick={(event) => { if (!(event.target as Element).closest(".timeline-bar")) selectDate(event); }}
          aria-label={messages.scheduleGantt}>
          <div className="workspace-chart-content" style={{ width: scale.width, backgroundSize: `${scale.dayWidth}px 100%` }}>
            <div className="timeline-nonworking-days" aria-hidden="true">
              {nonWorkingRanges.map((range) => <span key={`${range.startDay}:${range.dayCount}`}
                data-start-date={civilFromDay(range.startDay)}
                data-end-date={civilFromDay(range.startDay + range.dayCount - 1)}
                style={{ left: (range.startDay - scale.startDay) * scale.dayWidth, width: range.dayCount * scale.dayWidth }} />)}
            </div>
            {selectedDate && <div className="timeline-selected-column" data-date={selectedDate}
              style={{ left: timelinePosition(scale, selectedDate), width: scale.dayWidth }} />}
            {targets.map((target) => <button type="button" key={target.id} className="timeline-target-line"
              style={{ left: timelinePosition(scale, target.targetDate), borderColor: target.color }}
              title={messages.targetDetail(target.name, formatCivilDate(target.targetDate))}
              aria-label={`${messages.targetDetail(target.name, formatCivilDate(target.targetDate))}. ${canEdit ? messages.edit : messages.milestoneView}`}
              onClick={(event) => { event.stopPropagation(); setTargetDialog(target); }} />)}
            <div className="timeline-today-line" data-date={today}
              style={{ left: timelinePosition(scale, today) }}
              title={`${messages.today}: ${formatCivilDate(today)}`} />
            {rows.map((row) => {
              const interval = timelineInterval(scale, row.start, row.end);
              const impact = row.kind === "activity" ? impactByActivity.get(row.id) : undefined;
              const proposedInterval = impact
                ? timelineInterval(scale, impact.proposedStartDate, impact.proposedEndDate) : null;
              return <div key={row.key} className={`workspace-chart-row row-${row.kind}${selected === row.key ? " selected" : ""}`}
                data-row-key={row.key}
                onClick={() => setSelected(row.key)}>
                {interval && <button type="button" className={`timeline-bar bar-${row.kind}`}
                  style={{ left: interval.left, width: interval.width, backgroundColor: row.color ?? "var(--jl-gantt-line-fallback)" }}
                  title={messages.scheduleBarDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                  aria-label={messages.scheduleBarDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                  onClick={() => setSelected(row.key)} />}
                {proposedInterval && <span className="timeline-proposed-bar" data-activity-id={row.id}
                  aria-hidden="true" style={{ left: proposedInterval.left, width: proposedInterval.width }} />}
                {!interval && row.kind === "stage" && <span className="workspace-no-date">{messages.noActivities}</span>}
              </div>;
            })}
          </div>
        </div>
      </div>
      <div className="workspace-scrollbar-row" aria-label={messages.scheduleTimeline}>
        <div className="workspace-scrollbar-spacer" />
        <div className="workspace-divider-footer" />
        <div ref={scrollbarRef} className="workspace-horizontal-scroll" onScroll={() => syncScroll("scrollbar")}
          role="region" tabIndex={0} aria-label={messages.scheduleTimeline}>
          <div className="workspace-horizontal-content" style={{ width: scale.width }} />
        </div>
      </div>
    </div>
    {targetDialog && <TargetDialog target={targetDialog === "new" ? null : targetDialog}
      initialDate={selectedDate ?? today} canEdit={canEdit} userId={userId}
      onClose={() => setTargetDialog(null)} onCreate={onCreateTarget} onUpdate={onUpdateTarget}
      onDelete={onDeleteTarget} />}
    {deletionTarget && <div className="schedule-deletion-backdrop" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !deletionBusy) {
        deletionRequest.current++;
        setDeletionTarget(null);
        setDeletionPreview(null);
        queueMicrotask(() => deletionTrigger.current?.focus());
      }
    }}>
      <div ref={deletionDialog} className="schedule-deletion-dialog" role="alertdialog" aria-modal="true"
        aria-labelledby="schedule-deletion-title" aria-describedby="schedule-deletion-explanation">
        <h2 id="schedule-deletion-title">{messages.confirmScheduleDeletion}</h2>
        <p className="schedule-deletion-dialog__target">{messages.scheduleDeletionTarget(deletionTarget.kind, deletionTarget.label)}</p>
        <p id="schedule-deletion-explanation">{messages.scheduleDeletionExplanation}</p>
        {deletionLoading ? <p role="status">{messages.scheduleDeletionPreviewLoading}</p> : deletionPreview &&
          <p className="schedule-deletion-dialog__impact" aria-live="polite">{messages.scheduleDeletionImpact(
            deletionPreview.counts.disciplines, deletionPreview.counts.stages, deletionPreview.counts.activities)}</p>}
        {deletionError && <p role="alert" className="schedule-deletion-dialog__error">{deletionError}</p>}
        {deletionStale && <button type="button" disabled={deletionBusy} onClick={() =>
          void fetchDeletionPreview(deletionTarget, false)}>{messages.scheduleDeletionRefreshPreview}</button>}
        <form onSubmit={(event) => void confirmDeletion(event)}>
          <label htmlFor="schedule-deletion-reason">{messages.scheduleDeletionReason}</label>
          <textarea id="schedule-deletion-reason" maxLength={2000} required minLength={10}
            value={deletionReason} disabled={deletionBusy || !deletionPreview || deletionLoading}
            aria-describedby="schedule-deletion-reason-hint"
            onChange={(event) => { setDeletionReason(event.target.value); setDeletionError(""); }} />
          <small id="schedule-deletion-reason-hint">{messages.scheduleDeletionReasonHint}</small>
          <div className="schedule-deletion-dialog__actions">
            <button type="button" disabled={deletionBusy} onClick={() => {
              deletionRequest.current++;
              setDeletionTarget(null);
              setDeletionPreview(null);
              queueMicrotask(() => deletionTrigger.current?.focus());
            }}>{messages.scheduleDeletionCancel}</button>
            <button type="submit" disabled={deletionBusy || deletionLoading || !deletionPreview ||
              deletionStale || deletionReason.trim().length < 10}>
              {deletionBusy ? messages.scheduleDeletionSubmitting : messages.scheduleDeletionConfirm}
            </button>
          </div>
        </form>
      </div>
    </div>}
  </section>;
}

function TargetDialog({ target, initialDate, canEdit, userId, onClose, onCreate, onUpdate, onDelete }: {
  target: ScheduleTarget | null; initialDate: string; canEdit: boolean; userId?: string | null; onClose: () => void;
  onCreate: (value: { name: string; description: string | null; targetDate: string; color: string }) => Promise<ScheduleTarget>;
  onUpdate: (target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }) => Promise<ScheduleTarget>;
  onDelete: (target: ScheduleTarget) => Promise<void>;
}) {
  const [name, setName] = useState(target?.name ?? "");
  const [description, setDescription] = useState(target?.description ?? "");
  const [date, setDate] = useState(formatCivilDate(target?.targetDate ?? initialDate));
  const [color, setColor] = useState(target?.color ?? "#AA4557");
  const [colorSelected, setColorSelected] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const dateChanged = !!target && parseBrazilianDate(date) !== target.targetDate;
  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!name.trim()) { setError(messages.milestoneNameRequired); return; }
    const iso = parseBrazilianDate(date);
    if (!iso) { setError(messages.milestoneDateInvalid); return; }
    if (dateChanged && reason.trim().length < 10) { setError(messages.milestoneReasonRequired); return; }
    setBusy(true); setError("");
    try {
      const value = { name: name.trim(), description: description.trim() || null, targetDate: iso, color };
      if (target) await onUpdate(target, { ...value, reason: dateChanged ? reason.trim() : null });
      else await onCreate(value);
      if (colorSelected) rememberRecentCustomColor(userId, color);
      onClose();
    } catch (cause) { setError(cause instanceof Error ? cause.message : messages.milestoneSaveError); }
    finally { setBusy(false); }
  }
  async function remove() {
    if (!target || !window.confirm(messages.milestoneDeleteConfirm(target.name))) return;
    setBusy(true); setError("");
    try { await onDelete(target); onClose(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : messages.milestoneDeleteError); }
    finally { setBusy(false); }
  }
  return <div className="schedule-drawer-backdrop" onMouseDown={(event) => {
    if (event.target === event.currentTarget && !busy) onClose();
  }}><form className="milestone-dialog" role="dialog" aria-modal="true"
    aria-labelledby="milestone-dialog-title" onSubmit={(event) => void save(event)}>
    <h3 id="milestone-dialog-title">{target ? (canEdit ? messages.milestoneEdit : messages.milestoneView) : messages.milestoneCreate}</h3>
    <label htmlFor="milestone-name">{messages.milestoneName}</label>
    <input id="milestone-name" aria-required="true" maxLength={200} value={name} disabled={!canEdit || busy}
      onChange={(event) => setName(event.target.value)} />
    <label htmlFor="milestone-description">{messages.milestoneDescription}</label>
    <textarea id="milestone-description" maxLength={2000} value={description} disabled={!canEdit || busy}
      onChange={(event) => setDescription(event.target.value)} />
    <label htmlFor="milestone-date">{messages.milestoneDate}</label>
    <input id="milestone-date" inputMode="numeric" placeholder="DD/MM/AAAA" aria-required="true" value={date}
      disabled={!canEdit || busy} onChange={(event) => setDate(event.target.value)} />
    <ColorField id="milestone-color" label={messages.milestoneColor} value={color} userId={userId}
      disabled={!canEdit || busy} onChange={(value) => { setColor(value); setColorSelected(true); }} />
    {dateChanged && canEdit && <>
      <label htmlFor="milestone-reason">{messages.milestoneReason}</label>
      <textarea id="milestone-reason" maxLength={2000} aria-required="true" value={reason}
        aria-describedby="milestone-reason-hint" disabled={busy}
        onChange={(event) => setReason(event.target.value)} />
      <small id="milestone-reason-hint">{messages.milestoneReasonHint}</small>
    </>}
    {error && <p role="alert">{error}</p>}
    <div className="milestone-actions">
      {canEdit && <button type="submit" disabled={busy}>{messages.milestoneSave}</button>}
      {target && canEdit && <button type="button" disabled={busy} onClick={() => void remove()}>{messages.milestoneDelete}</button>}
      <button type="button" disabled={busy} onClick={onClose}>{target && !canEdit ? messages.milestoneClose : messages.milestoneCancel}</button>
    </div>
  </form></div>;
}
