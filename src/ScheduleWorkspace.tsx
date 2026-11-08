import { type CSSProperties, type MouseEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { civilFromDay, dayNumber, makeTimeline, saoPauloCivilDate, timelineDateAtPosition,
  timelineInterval, timelinePosition, visibleScheduleRows,
  type ScheduleTarget, type ScheduleTree, type VisibleRow, type Zoom } from "../domain/schedule-workspace";
import { formatCivilDate } from "./civil-date";
import { messages } from "./locales/pt-BR";

const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });

export function ScheduleWorkspace({ product, tree, targets, openDisciplines, openStages,
  canEdit, onToggle, onEdit, onAdd }: {
  product: { id: string; name: string }; tree: ScheduleTree; targets: ScheduleTarget[];
  openDisciplines: ReadonlySet<string>; openStages: ReadonlySet<string>; canEdit: boolean;
  onToggle: (row: VisibleRow) => void; onEdit: (row: VisibleRow) => void;
  onAdd: (row: VisibleRow) => void;
}) {
  const [zoom, setZoom] = useState<Zoom>("week");
  const [tableWidth, setTableWidth] = useState(50);
  const [selected, setSelected] = useState<string | null>(null);
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const [today, setToday] = useState(() => saoPauloCivilDate(new Date()));
  const [productExpanded, setProductExpanded] = useState(true);
  const [mobilePane, setMobilePane] = useState<"table" | "gantt">("table");
  const splitRef = useRef<HTMLDivElement>(null);
  const headerRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<HTMLDivElement>(null);
  const scrollbarRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);
  const rows = useMemo(() => visibleScheduleRows(product, tree, openDisciplines, openStages, productExpanded),
    [product, tree, openDisciplines, openStages, productExpanded]);
  const scale = useMemo(() => makeTimeline(tree, targets, zoom, today), [tree, targets, zoom, today]);

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
  return <section className="schedule-workspace" aria-label={messages.scheduleWorkspace}>
    <div className="workspace-controls">
      <label htmlFor="schedule-zoom">{messages.scheduleZoom}</label>
      <select id="schedule-zoom" value={zoom} onChange={(event) => setZoom(event.target.value as Zoom)}>
        <option value="day">{messages.zoomDay}</option>
        <option value="week">{messages.zoomWeek}</option>
        <option value="month">{messages.zoomMonth}</option>
      </select>
      <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(-1)}>{messages.timelineEarlier}</button>
      <button type="button" className="timeline-navigation" onClick={() => shiftTimeline(1)}>{messages.timelineLater}</button>
      {selectedDate && <span role="status" className="workspace-selected-date">
        {messages.selectedDate(formatCivilDate(selectedDate))}
        <button type="button" onClick={() => setSelectedDate(null)}>{messages.clearSelectedDate}</button>
      </span>}
      <span>{messages.targetCount(targets.length)}</span>
      <div className="workspace-mobile-switch" role="group" aria-label={messages.schedulePane}>
        <button type="button" aria-pressed={mobilePane === "table"} onClick={() => setMobilePane("table")}>{messages.scheduleTable}</button>
        <button type="button" aria-pressed={mobilePane === "gantt"} onClick={() => setMobilePane("gantt")}>{messages.scheduleGantt}</button>
      </div>
    </div>
    <div ref={splitRef} className={`workspace-split mobile-${mobilePane}`} style={style}>
      <div className="workspace-headers">
        <div className="workspace-table-header">
          <span>{messages.scheduleItem}</span><span>{messages.plannedStart}</span>
          <span>{messages.plannedEnd}</span><span>{messages.scheduleActions}</span>
        </div>
        <div className="workspace-divider-header" />
        <div ref={headerRef} className="workspace-timeline-header" onScroll={() => syncScroll("header")}
          onClick={selectDate} onKeyDown={(event) => {
            if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
              event.preventDefault();
              changeSelectedDate(event.key === "ArrowLeft" ? -1 : 1);
            }
          }} tabIndex={0} role="group" aria-label={messages.timelineDateInstructions}>
          <div className="timeline-head-content" style={{ width: scale.width }}>
            <div className="timeline-months">{scale.months.map((month) => <div key={month.startDay}
              className="timeline-month" style={{ width: month.days * scale.dayWidth }}>
              {monthLabel.format(new Date(month.startDay * 86_400_000))}
            </div>)}</div>
            <div className="timeline-ticks">{scale.ticks.map((day) => <span key={day} className="timeline-tick"
              style={{ left: (day - scale.startDay) * scale.dayWidth }}>
              {zoom === "month" ? formatCivilDate(civilFromDay(day)).slice(3) : formatCivilDate(civilFromDay(day)).slice(0, 5)}
            </span>)}</div>
            <div className="timeline-target-head">{targets.map((target) => <span key={target.id}
              className="timeline-target-label" style={{ left: timelinePosition(scale, target.targetDate) }}
              title={messages.targetDetail(target.name, formatCivilDate(target.targetDate))}>
              {messages.targetShortLabel(target.name)}
            </span>)}<span className="timeline-today-label" style={{ left: timelinePosition(scale, today) }}
              title={`${messages.today}: ${formatCivilDate(today)}`}>{messages.today}</span></div>
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
              <button type="button" className="workspace-row-name" title={row.label}
                onClick={() => setSelected(row.key)}>{row.label}{row.code ? ` (${row.code})` : ""}</button>
            </div>
            <span role="cell" className="workspace-date-cell">{formatCivilDate(row.start)}</span>
            <span role="cell" className="workspace-date-cell">{formatCivilDate(row.end)}</span>
            <span role="cell" className="workspace-row-actions">{canEdit && row.kind !== "product" && <button type="button"
              aria-label={row.kind === "discipline" ? messages.editDiscipline : row.kind === "stage" ? messages.editStage : messages.editActivity}
              onClick={() => { setSelected(row.key); onEdit(row); }}>{messages.edit}</button>}
              {canEdit && (row.kind === "discipline" || row.kind === "stage") && <button type="button"
                aria-label={row.kind === "discipline" ? messages.addStage : messages.addActivity}
                onClick={() => { setSelected(row.key); onAdd(row); }}>{messages.add}</button>}</span>
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
            {targets.map((target) => <div key={target.id} className="timeline-target-line"
              style={{ left: timelinePosition(scale, target.targetDate) }}
              title={messages.targetDetail(target.name, formatCivilDate(target.targetDate))} />)}
            <div className="timeline-today-line" data-date={today}
              style={{ left: timelinePosition(scale, today) }}
              title={`${messages.today}: ${formatCivilDate(today)}`} />
            {rows.map((row) => {
              const interval = timelineInterval(scale, row.start, row.end);
              return <div key={row.key} className={`workspace-chart-row row-${row.kind}${selected === row.key ? " selected" : ""}`}
                data-row-key={row.key}
                onClick={() => setSelected(row.key)}>
                {interval && <button type="button" className={`timeline-bar bar-${row.kind}`}
                  style={{ left: interval.left, width: interval.width, backgroundColor: row.color ?? "#173f64" }}
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
  </section>;
}
