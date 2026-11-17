import { type MouseEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { groupExecutiveOverflow, groupExecutiveTargets, makeExecutiveTimeline,
  packExecutiveStages } from "../domain/executive-gantt-view";
import { nonWorkingDayRanges } from "../domain/non-working-day-ranges";
import { parseCivilDate, type CalendarExceptionDates } from "../domain/working-calendar";
import { civilFromDay, dayNumber, saoPauloCivilDate, timelineInterval, timelinePosition } from "../domain/schedule-workspace";
import type { ExecutiveDiscipline, ExecutiveProduct, ExecutiveStage, ExecutiveTarget } from "../worker/executive-gantt";
import { authenticatedFetch } from "./auth";
import { formatCivilDate } from "./civil-date";
import { ganttTextColor } from "./design/gantt-colors";
import { messages } from "./locales/pt-BR";

const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
const compactRowHeight = 80;
const compactVisibleLanes = 2;
const compactStageWidth = 28;
type StageDetail = { stage: ExecutiveStage; discipline: ExecutiveDiscipline };

function isExecutiveProduct(value: unknown): value is ExecutiveProduct {
  if (!value || typeof value !== "object") return false;
  const product = value as Partial<ExecutiveProduct>;
  return typeof product.id === "string" && typeof product.name === "string" &&
    typeof product.active === "boolean" && Array.isArray(product.rootActivities) &&
    Array.isArray(product.targets) && Array.isArray(product.disciplines) &&
    product.disciplines.every((discipline) => Array.isArray(discipline.stages) &&
      discipline.stages.every((stage) => Array.isArray(stage.activities)));
}

function milestoneDetail(target: ExecutiveTarget): string {
  return messages.targetDetail(target.name, formatCivilDate(target.targetDate));
}

export function ExecutiveGanttHome({ workspaceId, onAccessLost, onOpenFull }: {
  workspaceId: string;
  onAccessLost: () => void;
  onOpenFull?: () => void;
}) {
  const [products, setProducts] = useState<ExecutiveProduct[]>([]);
  const [loadedWorkspaceId, setLoadedWorkspaceId] = useState(workspaceId);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [showArchived, setShowArchived] = useState(true);
  const [showTargets, setShowTargets] = useState(true);
  const [zoom, setZoom] = useState<"week" | "month">("month");
  const [today, setToday] = useState(() => saoPauloCivilDate(new Date()));
  const [calendarExceptions, setCalendarExceptions] = useState<CalendarExceptionDates[]>([]);
  const [detail, setDetail] = useState<{ productName: string; stages: StageDetail[] } | null>(null);
  const requestId = useRef(0);
  const viewportRef = useRef<HTMLDivElement>(null);
  const detailTrigger = useRef<HTMLButtonElement | null>(null);
  const detailCloseButton = useRef<HTMLButtonElement>(null);

  const load = useCallback(async () => {
    const currentRequest = ++requestId.current;
    setLoadedWorkspaceId(workspaceId);
    setProducts([]);
    setCalendarExceptions([]);
    setDetail(null);
    setStatus("loading");
    try {
      const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/executive-gantt`);
      if (currentRequest !== requestId.current) return;
      if (response.status === 401 || response.status === 403) {
        onAccessLost();
        return;
      }
      if (!response.ok) throw new Error("Executive Gantt request failed.");
      const body: unknown = await response.json();
      if (currentRequest !== requestId.current) return;
      if (!body || typeof body !== "object" || !Array.isArray((body as { products?: unknown }).products) ||
        !(body as { products: unknown[] }).products.every(isExecutiveProduct))
        throw new Error("Executive Gantt response is invalid.");
      setProducts((body as { products: ExecutiveProduct[] }).products);
      setStatus("ready");
    } catch {
      if (currentRequest === requestId.current) setStatus("error");
    }
  }, [workspaceId, onAccessLost]);

  useEffect(() => {
    const requests = requestId;
    queueMicrotask(() => void load());
    return () => { requests.current++; };
  }, [load]);
  useEffect(() => {
    const timer = window.setInterval(() => setToday(saoPauloCivilDate(new Date())), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  const displayStatus = loadedWorkspaceId === workspaceId ? status : "loading";
  const visibleProducts = useMemo(() => loadedWorkspaceId !== workspaceId ? []
    : showArchived ? products : products.filter((product) => product.active),
  [loadedWorkspaceId, workspaceId, products, showArchived]);
  const timeline = useMemo(() => makeExecutiveTimeline(visibleProducts, zoom, today), [visibleProducts, zoom, today]);
  const calendarYearKey = useMemo(() => {
    const first = Number(civilFromDay(timeline.startDay).slice(0, 4));
    const last = Number(civilFromDay(timeline.endDay).slice(0, 4));
    return Array.from({ length: last - first + 1 }, (_, index) => first + index)
      .filter((year) => year >= 2026 && year <= 2100).join(",");
  }, [timeline.startDay, timeline.endDay]);
  useEffect(() => {
    if (displayStatus !== "ready" || !visibleProducts.length || !calendarYearKey) return;
    let active = true;
    const years = calendarYearKey.split(",").map(Number);
    void Promise.all(years.map(async (year): Promise<CalendarExceptionDates[]> => {
      try {
        const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/calendar?year=${year}`);
        if (response.status === 401 || response.status === 403) {
          if (active) onAccessLost();
          return [];
        }
        if (!response.ok) return [];
        const body = await response.json() as { calendar?: { exceptions?: unknown } };
        if (!Array.isArray(body.calendar?.exceptions)) return [];
        return body.calendar.exceptions.filter((item): item is CalendarExceptionDates => {
          if (!item || typeof item !== "object") return false;
          const candidate = item as Partial<CalendarExceptionDates>;
          return ["municipal_holiday", "collective_vacation", "company_shutdown"].includes(candidate.kind ?? "") &&
            typeof candidate.startDate === "string" && !!parseCivilDate(candidate.startDate) &&
            typeof candidate.endDate === "string" && !!parseCivilDate(candidate.endDate) &&
            candidate.startDate <= candidate.endDate;
        });
      } catch { return []; }
    })).then((groups) => { if (active) setCalendarExceptions(groups.flat()); });
    return () => { active = false; };
  }, [calendarYearKey, onAccessLost, displayStatus, visibleProducts, workspaceId]);
  const nonWorking = useMemo(() => nonWorkingDayRanges(timeline.startDay, timeline.endDay, calendarExceptions),
    [timeline.startDay, timeline.endDay, calendarExceptions]);
  const todayLeft = timelinePosition(timeline, today);
  useEffect(() => {
    if (displayStatus !== "ready" || !viewportRef.current) return;
    const dated = visibleProducts.flatMap((product) => [product.start, product.end,
      ...product.targets.map((target) => target.targetDate)]).filter((date): date is string => !!date);
    const sorted = dated.sort();
    const focus = sorted.length ? Math.max(dayNumber(sorted[0]), Math.min(dayNumber(today), dayNumber(sorted.at(-1)!)))
      : dayNumber(today);
    const labelWidth = viewportRef.current.querySelector(".executive-gantt__header-label")?.getBoundingClientRect().width || 220;
    viewportRef.current.scrollLeft = Math.max(0, (focus - timeline.startDay) * timeline.dayWidth -
      (viewportRef.current.clientWidth - labelWidth) / 2);
  }, [displayStatus, workspaceId, zoom, showArchived, visibleProducts, timeline, today]);

  function openDetails(event: MouseEvent<HTMLButtonElement>, productName: string, stages: StageDetail[]) {
    detailTrigger.current = event.currentTarget;
    setDetail({ productName, stages });
  }

  function closeDetails() {
    setDetail(null);
    if (detailTrigger.current?.isConnected) detailTrigger.current.focus();
  }

  return <section className="executive-gantt" aria-labelledby="executive-gantt-title">
    <div className="executive-gantt__heading">
      <h3 id="executive-gantt-title">{messages.executiveGanttTitle}</h3>
      <p>{messages.executiveGanttDescription}</p>
    </div>
    <div className="workspace-controls executive-gantt__controls" role="toolbar" aria-label={messages.executiveToolbar}>
      <div className="workspace-zoom" role="group" aria-label={messages.scheduleZoom}>
        {([["month", messages.zoomMonth], ["week", messages.zoomWeek]] as const).map(([value, label]) =>
          <button key={value} type="button" aria-pressed={zoom === value}
            onClick={() => setZoom(value)}>{label}</button>)}
      </div>
      <label className="executive-gantt__toggle"><input type="checkbox" checked={showArchived}
        onChange={(event) => setShowArchived(event.target.checked)} />
        {messages.executiveShowArchived}</label>
      <label className="executive-gantt__toggle"><input type="checkbox" checked={showTargets}
        onChange={(event) => setShowTargets(event.target.checked)} />
        {messages.executiveShowTargets}</label>
      <div className="executive-gantt__toolbar-actions">
        <button type="button" className="back-button" onClick={() => void load()}>{messages.executiveRefresh}</button>
        <button type="button" disabled={!onOpenFull} onClick={onOpenFull}
          title={onOpenFull ? undefined : messages.executiveGanttFullPending}>{messages.openExecutiveGantt}</button>
      </div>
    </div>
    {displayStatus === "loading" && <p role="status">{messages.executiveLoading}</p>}
    {displayStatus === "error" && <p role="alert">{messages.executiveError}</p>}
    {displayStatus === "ready" && products.length === 0 && <p>{messages.executiveEmpty}</p>}
    {displayStatus === "ready" && products.length > 0 && visibleProducts.length === 0 && <p>{messages.executiveFilteredEmpty}</p>}
    {displayStatus === "ready" && visibleProducts.length > 0 && <div className="executive-gantt__viewport" ref={viewportRef}
      role="table" aria-label={messages.executiveGanttTitle}>
      <div className="executive-gantt__header" role="row"
        style={{ width: `calc(var(--executive-label-width) + ${timeline.width}px)` }}>
        <div className="executive-gantt__header-label" role="columnheader">{messages.products}</div>
        <div className="executive-gantt__header-chart" role="columnheader" style={{ width: timeline.width }}>
          <div className="executive-gantt__months">{timeline.months.map((month) => <span key={month.startDay}
            style={{ width: month.days * timeline.dayWidth }}>
            {monthLabel.format(new Date(month.startDay * 86_400_000))}</span>)}</div>
          <div className="executive-gantt__ticks">{timeline.ticks.map((day) => <span key={day}
            style={{ left: (day - timeline.startDay) * timeline.dayWidth }}>
            {zoom === "month" ? formatCivilDate(civilFromDay(day)).slice(3)
              : formatCivilDate(civilFromDay(day)).slice(0, 5)}</span>)}</div>
          <span className="executive-gantt__today-heading" style={{ left: todayLeft }}
            title={`${messages.today}: ${formatCivilDate(today)}`}>{messages.today}</span>
        </div>
      </div>
      {visibleProducts.map((product) => {
        const packed = packExecutiveStages(product, Math.ceil(compactStageWidth / timeline.dayWidth));
        const visibleStages = packed.stages.filter((item) => item.lane < compactVisibleLanes);
        const hiddenStages = packed.stages.filter((item) => item.lane >= compactVisibleLanes);
        const overflowGroups = groupExecutiveOverflow(hiddenStages, timeline, compactStageWidth);
        const additionalStages = [...hiddenStages, ...packed.undated];
        const clusters = showTargets ? groupExecutiveTargets(product.targets) : [];
        const range = `${formatCivilDate(product.start)} – ${formatCivilDate(product.end)}`;
        return <div key={product.id} className="executive-gantt__row" role="row" data-product-id={product.id}
          style={{ width: `calc(var(--executive-label-width) + ${timeline.width}px)`, height: compactRowHeight }}>
          <div className="executive-gantt__product" role="rowheader">
            <span className="executive-gantt__product-topline"><strong title={product.name}>{product.name}</strong>
              {!product.active && <span className="executive-gantt__archived">{messages.archived}</span>}</span>
            <small title={range}>{range}</small>
            {additionalStages.length > 0 && <button type="button" className="executive-gantt__more-stages"
              aria-label={messages.executiveMoreStagesForProduct(product.name, additionalStages.length)}
              onClick={(event) => openDetails(event, product.name, additionalStages)}>
              {messages.executiveMoreStages(additionalStages.length)}</button>}
          </div>
          <div className="executive-gantt__chart" role="cell" style={{ width: timeline.width, height: compactRowHeight }}>
            <div className="executive-gantt__nonworking" aria-hidden="true">{nonWorking.map((range) =>
              <span key={range.startDay} data-start-date={civilFromDay(range.startDay)}
                data-end-date={civilFromDay(range.startDay + range.dayCount - 1)}
                style={{ left: (range.startDay - timeline.startDay) * timeline.dayWidth,
                width: range.dayCount * timeline.dayWidth }} />)}</div>
            <span className="executive-gantt__today-line" aria-hidden="true" style={{ left: todayLeft }} />
            {visibleStages.map(({ stage, discipline, lane, anchorDate, partial }) => {
              const interval = partial ? null : timelineInterval(timeline, stage.start, stage.end);
              const stageLabel = messages.executiveStageDetail(stage.displayName, discipline.name,
                formatCivilDate(stage.start), formatCivilDate(stage.end));
              return <span key={stage.id} data-stage-id={stage.id} data-lane={lane}
                className={`executive-gantt__stage${partial ? " executive-gantt__stage--partial" : ""}${!partial &&
                  interval && interval.width < 74 ? " executive-gantt__stage--short" : ""}`}
                role="img" tabIndex={0} aria-label={stageLabel} title={stageLabel}
                style={{ top: 5 + lane * 19, left: interval?.left ?? timelinePosition(timeline, anchorDate),
                  width: Math.max(interval?.width ?? 0, compactStageWidth), backgroundColor: stage.color,
                  color: ganttTextColor(stage.color) }}>
                {interval && interval.width >= 74 ? stage.displayName : stage.code.slice(0, 2)}</span>;
            })}
            {overflowGroups.map((group) => <button key={`${group.left}-${group.stages[0].stage.id}`}
              type="button" className="executive-gantt__overflow" data-overflow-count={group.stages.length}
              style={{ top: 43, left: group.left, width: group.width }}
              aria-label={messages.executiveOverlapDetails(group.stages.length)}
              title={group.stages.map(({ stage, discipline }) => messages.executiveStageDetail(stage.displayName,
                discipline.name, formatCivilDate(stage.start), formatCivilDate(stage.end))).join("\n")}
              onClick={(event) => openDetails(event, product.name, group.stages)}>
              <span className="executive-gantt__overflow-colors" aria-hidden="true">{group.stages.slice(0, 3).map(({ stage }) =>
                <i key={stage.id} style={{ backgroundColor: stage.color }} />)}</span>
              <span>+{group.stages.length}</span>
            </button>)}
            {clusters.map((cluster) => <div key={cluster.date} className="executive-gantt__target-cluster"
              data-target-date={cluster.date} role="img" tabIndex={0}
              aria-label={messages.executiveTargetCluster(cluster.targets.map(milestoneDetail))}
              title={cluster.targets.map(milestoneDetail).join("\n")}
              style={{ left: timelinePosition(timeline, cluster.date) + timeline.dayWidth / 2, top: 61 }}>
              <span className="executive-gantt__diamonds" aria-hidden="true">{cluster.targets.slice(0, 3).map((target) =>
                <span key={target.id} className="executive-gantt__diamond" style={{ backgroundColor: target.color }} />)}</span>
              {cluster.targets.length > 1 && <span className="executive-gantt__target-count" aria-hidden="true">
                {cluster.targets.length}</span>}
              <span className="executive-gantt__target-detail" aria-hidden="true">{cluster.targets.map((target) =>
                <span key={target.id}><i style={{ backgroundColor: target.color }} />{target.name}</span>)}</span>
            </div>)}
          </div>
        </div>;
      })}
    </div>}
    {detail && displayStatus === "ready" && <div className="executive-gantt__dialog-backdrop"
      onMouseDown={(event) => { if (event.target === event.currentTarget) closeDetails(); }}>
      <div className="executive-gantt__dialog" role="dialog" aria-modal="true"
        aria-labelledby="executive-stage-detail-title" onKeyDown={(event) => {
          if (event.key === "Escape") { event.stopPropagation(); closeDetails(); }
          if (event.key === "Tab") { event.preventDefault(); detailCloseButton.current?.focus(); }
        }}>
        <div className="executive-gantt__dialog-heading">
          <h4 id="executive-stage-detail-title">{messages.executiveStageListTitle(detail.productName)}</h4>
          <button type="button" className="back-button" ref={detailCloseButton} autoFocus onClick={closeDetails}>
            {messages.executiveCloseDetails}</button>
        </div>
        <p>{messages.executiveStageListDescription}</p>
        <ul>{detail.stages.map(({ stage, discipline }) => <li key={stage.id} data-detail-stage-id={stage.id}>
          <span className="executive-gantt__detail-color" style={{ backgroundColor: stage.color }} aria-hidden="true" />
          <span><strong>{stage.displayName}</strong><small>{stage.code} · {discipline.name}</small>
            <small>{formatCivilDate(stage.start)} – {formatCivilDate(stage.end)}</small>
            <small>{messages.scheduleColor(stage.color)}</small></span>
        </li>)}</ul>
      </div>
    </div>}
  </section>;
}
