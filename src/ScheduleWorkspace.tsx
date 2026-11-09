import { type CSSProperties, type FormEvent, type MouseEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { civilFromDay, dayNumber, makeTimeline, saoPauloCivilDate, timelineDateAtPosition,
  timelineInterval, timelinePosition, visibleScheduleRows,
  type ScheduleTarget, type ScheduleTree, type VisibleRow, type Zoom } from "../domain/schedule-workspace";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { messages } from "./locales/pt-BR";
import { ColorField } from "./ColorField";
import { layoutMilestoneLabels } from "./design/gantt-colors";

const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });

export function ScheduleWorkspace({ product, tree, targets, openDisciplines, openStages,
  canEdit, onToggle, onEdit, onAdd, onAddDiscipline, onRefresh, onHistory, onCreateTarget, onUpdateTarget, onDeleteTarget }: {
  product: { id: string; name: string }; tree: ScheduleTree; targets: ScheduleTarget[];
  openDisciplines: ReadonlySet<string>; openStages: ReadonlySet<string>; canEdit: boolean;
  onToggle: (row: VisibleRow) => void; onEdit: (row: VisibleRow) => void;
  onAdd: (row: VisibleRow) => void; onHistory: (row: VisibleRow) => void;
  onAddDiscipline: () => void; onRefresh: () => void;
  onCreateTarget: (value: { name: string; description: string | null; targetDate: string; color: string }) => Promise<ScheduleTarget>;
  onUpdateTarget: (target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }) => Promise<ScheduleTarget>;
  onDeleteTarget: (target: ScheduleTarget) => Promise<void>;
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
  const splitRef = useRef<HTMLDivElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<HTMLDivElement>(null);
  const scrollbarRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);
  const rows = useMemo(() => visibleScheduleRows(product, tree, openDisciplines, openStages, productExpanded),
    [product, tree, openDisciplines, openStages, productExpanded]);
  const scale = useMemo(() => makeTimeline(tree, targets, zoom, today, bounds), [tree, targets, zoom, today, bounds]);
  const milestoneLabels = useMemo(() => layoutMilestoneLabels(targets,
    (date) => timelinePosition(scale, date), scale.width), [targets, scale]);
  const milestoneLaneCount = milestoneLabels.reduce((count, label) => Math.max(count, label.lane + 1), 0);
  const targetHeadHeight = Math.max(29, milestoneLaneCount * 18 + 22);
  const headerHeight = Math.max(82, 28 + 24 + targetHeadHeight);

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
    const position = scrollbarRef.current?.scrollLeft ?? 0;
    if (headerRef.current) headerRef.current.scrollLeft = position;
    if (chartRef.current) chartRef.current.scrollLeft = position;
  }, [scale.width, tableWidth]);

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
        <button type="button" onClick={onRefresh}>{messages.refreshHierarchy}</button>
      </div>
      <div className="workspace-zoom" role="group" aria-label={messages.scheduleZoom}>
        {([ ["day", messages.zoomDay], ["week", messages.zoomWeek], ["month", messages.zoomMonth] ] as const).map(([value, label]) =>
          <button key={value} type="button" aria-pressed={zoom === value}
            onClick={() => setZoom(value)}>{label}</button>)}
      </div>
      <div className="workspace-timeline-navigation" role="group" aria-label={messages.scheduleTimeline}>
        <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(-1)}>{messages.timelineEarlier}</button>
        <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(1)}>{messages.timelineLater}</button>
      </div>
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
        <div className="workspace-table-rows" role="table" aria-label={messages.scheduleTable}>
          {rows.map((row) => <div key={row.key} className={`workspace-table-row row-${row.kind}${selected === row.key ? " selected" : ""}`}
            data-row-key={row.key} role="row" aria-selected={selected === row.key}>
            <div role="cell" className="workspace-name-cell" style={{ paddingLeft: `${({ product: 0, discipline: 12, stage: 27, activity: 42 })[row.kind]}px` }}>
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
                {row.kind === "activity" && !canEdit && <button type="button" className="workspace-icon-action"
                  title={messages.activityDateHistory} onClick={() => { setSelected(row.key); onHistory(row); }}
                  aria-label={messages.activityDateHistory}>
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
              return <div key={row.key} className={`workspace-chart-row row-${row.kind}${selected === row.key ? " selected" : ""}`}
                data-row-key={row.key}
                onClick={() => setSelected(row.key)}>
                {interval && <button type="button" className={`timeline-bar bar-${row.kind}`}
                  style={{ left: interval.left, width: interval.width, backgroundColor: row.color ?? "var(--jl-gantt-line-fallback)" }}
                  title={messages.scheduleBarDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                  aria-label={messages.scheduleBarDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                  onClick={() => setSelected(row.key)} />}
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
      initialDate={selectedDate ?? today} canEdit={canEdit}
      onClose={() => setTargetDialog(null)} onCreate={onCreateTarget} onUpdate={onUpdateTarget}
      onDelete={onDeleteTarget} />}
  </section>;
}

function TargetDialog({ target, initialDate, canEdit, onClose, onCreate, onUpdate, onDelete }: {
  target: ScheduleTarget | null; initialDate: string; canEdit: boolean; onClose: () => void;
  onCreate: (value: { name: string; description: string | null; targetDate: string; color: string }) => Promise<ScheduleTarget>;
  onUpdate: (target: ScheduleTarget, value: { name: string; description: string | null;
    targetDate: string; color: string; reason: string | null }) => Promise<ScheduleTarget>;
  onDelete: (target: ScheduleTarget) => Promise<void>;
}) {
  const [name, setName] = useState(target?.name ?? "");
  const [description, setDescription] = useState(target?.description ?? "");
  const [date, setDate] = useState(formatCivilDate(target?.targetDate ?? initialDate));
  const [color, setColor] = useState(target?.color ?? "#AA4557");
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
    <ColorField id="milestone-color" label={messages.milestoneColor} value={color}
      disabled={!canEdit || busy} onChange={setColor} />
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
