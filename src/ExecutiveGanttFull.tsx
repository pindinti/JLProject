import { type MouseEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { visibleExecutiveFullRows, type ExecutiveCollapsed, type ExecutiveDetailLevel,
  type ExecutiveFullRow } from "../domain/executive-gantt-full";
import { executiveStageBarLabel, groupExecutiveTargets, makeExecutiveTimeline, packExecutiveStages } from "../domain/executive-gantt-view";
import { nonWorkingDayRanges } from "../domain/non-working-day-ranges";
import { civilFromDay, dayNumber, saoPauloCivilDate, timelineInterval, timelinePosition,
  stageDateDiscrepancies, type TimelineScale, type Zoom } from "../domain/schedule-workspace";
import { parseCivilDate, type CalendarExceptionDates } from "../domain/working-calendar";
import type { ExecutiveProduct, ExecutiveTarget } from "../worker/executive-gantt";
import { authenticatedFetch } from "./auth";
import { formatCivilDate } from "./civil-date";
import { ganttTextColor } from "./design/gantt-colors";
import { messages } from "./locales/pt-BR";

const monthLabel = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
const emptyIds = () => new Set<string>();
const noProducts: ExecutiveProduct[] = [];
const detailLevels = ["products", "disciplines", "stages", "activities"] as const;
const zoomLevels = ["day", "week", "month"] as const;

function isExecutiveProduct(value: unknown): value is ExecutiveProduct {
  if (!value || typeof value !== "object") return false;
  const product = value as Partial<ExecutiveProduct>;
  return typeof product.id === "string" && typeof product.name === "string" &&
    typeof product.active === "boolean" && Array.isArray(product.rootActivities) &&
    Array.isArray(product.targets) && Array.isArray(product.disciplines) &&
    product.disciplines.every((discipline) => Array.isArray(discipline.stages) &&
      discipline.stages.every((stage) => Array.isArray(stage.activities)));
}

function targetDetails(target: ExecutiveTarget): string {
  return [messages.targetDetail(target.name, formatCivilDate(target.targetDate)), target.description,
    target.operationalDate ? messages.executiveOperationalDate(formatCivilDate(target.operationalDate)) : null]
    .filter(Boolean).join(" · ");
}

function TargetMarkers({ product, scale, top, onOpen }: {
  product: ExecutiveProduct; scale: TimelineScale; top: number;
  onOpen: (event: MouseEvent<HTMLButtonElement>, product: ExecutiveProduct, targets: ExecutiveTarget[]) => void;
}) {
  return groupExecutiveTargets(product.targets).map((cluster) => <button key={cluster.date} type="button"
    className="executive-full__target" data-target-date={cluster.date}
    style={{ left: timelinePosition(scale, cluster.date) + scale.dayWidth / 2, top }}
    aria-label={messages.executiveTargetGroup(cluster.targets.map(targetDetails))}
    title={cluster.targets.map(targetDetails).join("\n")}
    onClick={(event) => { event.stopPropagation(); onOpen(event, product, cluster.targets); }}>
    <span className="executive-full__diamonds" aria-hidden="true">{cluster.targets.slice(0, 3).map((target) =>
      <i key={target.id} style={{ backgroundColor: target.color }} />)}</span>
    {cluster.targets.length > 1 && <span className="executive-full__target-count" aria-hidden="true">
      {cluster.targets.length}</span>}
  </button>);
}

function RowBar({ row, scale }: { row: ExecutiveFullRow; scale: TimelineScale }) {
  const interval = timelineInterval(scale, row.start, row.end);
  const anchor = row.start ?? row.end;
  const sourceLabel = row.kind === "stage" && row.stage
    ? row.stage.dateSource === "planned" ? messages.stageDateSourcePlanned : messages.stageDateSourceDerived : "";
  const discrepancyText = row.kind === "stage" && row.stage ? stageDateDiscrepancies(row.stage).map((warning) =>
    warning.boundary === "start"
      ? messages.stageDateActivityBeforeStart(warning.activityName, formatCivilDate(warning.activityDate),
        formatCivilDate(warning.stageDate))
      : messages.stageDateActivityAfterEnd(warning.activityName, formatCivilDate(warning.activityDate),
        formatCivilDate(warning.stageDate))) : [];
  const title = [messages.executiveFullRowDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end)),
    sourceLabel, ...discrepancyText].filter(Boolean).join(". ");
  const sourceClass = row.kind === "stage" && row.stage ? ` executive-full__bar--${row.stage.dateSource}` : "";
  if (interval) return <span className={`executive-full__bar executive-full__bar--${row.kind}${sourceClass}`}
    data-entity-id={row.id} role="img" tabIndex={0} aria-label={title} title={title}
    data-date-source={row.kind === "stage" ? row.stage?.dateSource : undefined}
    style={{ left: interval.left, width: Math.max(4, interval.width),
      backgroundColor: row.color ?? "var(--jl-primary)", color: row.color ? ganttTextColor(row.color) : "#FFFFFF" }} />;
  if (anchor) return <span className={`executive-full__bar executive-full__bar--partial${sourceClass}`}
    data-entity-id={row.id} role="img" tabIndex={0} aria-label={title} title={title}
    data-date-source={row.kind === "stage" ? row.stage?.dateSource : undefined}
    style={{ left: timelinePosition(scale, anchor), backgroundColor: row.color ?? "var(--jl-primary)" }} />;
  return null;
}

export function ExecutiveGanttFull({ workspaceId, onAccessLost, onBack, onOpenProduct }: {
  workspaceId: string;
  onAccessLost: () => void;
  onBack: () => void;
  onOpenProduct: (productId: string) => void;
}) {
  const [products, setProducts] = useState<ExecutiveProduct[]>([]);
  const [loadedWorkspaceId, setLoadedWorkspaceId] = useState(workspaceId);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [level, setLevel] = useState<ExecutiveDetailLevel>("products");
  const [zoom, setZoom] = useState<Zoom>("month");
  const [showArchived, setShowArchived] = useState(true);
  const [showTargets, setShowTargets] = useState(true);
  const [productFilter, setProductFilter] = useState("");
  const [disciplineFilter, setDisciplineFilter] = useState("");
  const [collapsedProducts, setCollapsedProducts] = useState<Set<string>>(emptyIds);
  const [collapsedDisciplines, setCollapsedDisciplines] = useState<Set<string>>(emptyIds);
  const [collapsedStages, setCollapsedStages] = useState<Set<string>>(emptyIds);
  const [selectedRow, setSelectedRow] = useState<string | null>(null);
  const [targetDialog, setTargetDialog] = useState<{ product: ExecutiveProduct; targets: ExecutiveTarget[] } | null>(null);
  const [calendarExceptions, setCalendarExceptions] = useState<CalendarExceptionDates[]>([]);
  const [today, setToday] = useState(() => saoPauloCivilDate(new Date()));
  const requestId = useRef(0);
  const viewport = useRef<HTMLDivElement>(null);
  const targetTrigger = useRef<HTMLButtonElement | null>(null);
  const dialogClose = useRef<HTMLButtonElement>(null);

  const load = useCallback(async () => {
    const current = ++requestId.current;
    setLoadedWorkspaceId(workspaceId);
    setProducts([]);
    setCalendarExceptions([]);
    setTargetDialog(null);
    setStatus("loading");
    try {
      const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/executive-gantt`);
      if (current !== requestId.current) return;
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (!response.ok) throw new Error("Executive Gantt request failed.");
      const body: unknown = await response.json();
      if (current !== requestId.current) return;
      if (!body || typeof body !== "object" || !Array.isArray((body as { products?: unknown }).products) ||
        !(body as { products: unknown[] }).products.every(isExecutiveProduct))
        throw new Error("Executive Gantt response is invalid.");
      setProducts((body as { products: ExecutiveProduct[] }).products);
      setStatus("ready");
    } catch { if (current === requestId.current) setStatus("error"); }
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
  const availableProducts = loadedWorkspaceId === workspaceId ? products : noProducts;
  const productOptions = useMemo(() => availableProducts.filter((product) => showArchived || product.active),
    [availableProducts, showArchived]);
  const disciplineOptions = useMemo(() => productOptions.filter((product) => !productFilter || product.id === productFilter)
    .flatMap((product) => product.disciplines.map((discipline) => ({ product, discipline }))),
  [productOptions, productFilter]);
  const visibleProducts = useMemo(() => productOptions.filter((product) =>
    (!productFilter || product.id === productFilter) &&
    (!disciplineFilter || product.disciplines.some((discipline) => discipline.id === disciplineFilter))),
  [productOptions, productFilter, disciplineFilter]);
  const collapsed: ExecutiveCollapsed = useMemo(() => ({ products: collapsedProducts,
    disciplines: collapsedDisciplines, stages: collapsedStages }),
  [collapsedProducts, collapsedDisciplines, collapsedStages]);
  const rows = useMemo(() => visibleExecutiveFullRows(visibleProducts, level, collapsed, disciplineFilter || null),
    [visibleProducts, level, collapsed, disciplineFilter]);
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
    void Promise.all(calendarYearKey.split(",").map(async (value): Promise<CalendarExceptionDates[]> => {
      try {
        const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/calendar?year=${value}`);
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
  }, [calendarYearKey, displayStatus, visibleProducts.length, workspaceId, onAccessLost]);
  const nonWorking = useMemo(() => nonWorkingDayRanges(timeline.startDay, timeline.endDay, calendarExceptions),
    [timeline.startDay, timeline.endDay, calendarExceptions]);
  const todayLeft = timelinePosition(timeline, today);
  useEffect(() => {
    if (displayStatus !== "ready" || !viewport.current) return;
    const dates = visibleProducts.flatMap((product) => [product.start, product.end,
      ...product.targets.map((target) => target.targetDate)]).filter((date): date is string => !!date).sort();
    const focus = dates.length ? Math.max(dayNumber(dates[0]), Math.min(dayNumber(today), dayNumber(dates.at(-1)!)))
      : dayNumber(today);
    const labelWidth = viewport.current.querySelector(".executive-full__label-head")?.getBoundingClientRect().width || 320;
    viewport.current.scrollLeft = Math.max(0, timelinePosition(timeline, civilFromDay(focus)) -
      (viewport.current.clientWidth - labelWidth) / 2);
  }, [displayStatus, timeline, visibleProducts, today, level, productFilter, disciplineFilter]);

  function toggleRow(row: ExecutiveFullRow) {
    const setter = row.kind === "product" ? setCollapsedProducts
      : row.kind === "discipline" ? setCollapsedDisciplines : setCollapsedStages;
    setter((current) => { const next = new Set(current); if (next.has(row.id)) next.delete(row.id); else next.add(row.id); return next; });
  }
  function openTargets(event: MouseEvent<HTMLButtonElement>, product: ExecutiveProduct, targets: ExecutiveTarget[]) {
    targetTrigger.current = event.currentTarget;
    setTargetDialog({ product, targets });
  }
  function closeTargets() {
    setTargetDialog(null);
    if (targetTrigger.current?.isConnected) targetTrigger.current.focus();
  }

  return <section className="executive-full" aria-labelledby="executive-full-title">
    <div className="executive-full__heading"><div><h2 id="executive-full-title">{messages.executiveFullTitle}</h2>
      <p>{messages.executiveFullDescription}</p></div>
      <button type="button" className="back-button" onClick={onBack}>{messages.backToProducts}</button></div>
    <div className="executive-full__toolbar" role="toolbar" aria-label={messages.executiveFullControls}>
      <div className="executive-full__detail-control" role="group" aria-label={messages.executiveDetailLevel}>
        {detailLevels.map((value) => <button key={value} type="button" aria-pressed={level === value}
          onClick={() => { setLevel(value); setSelectedRow(null); }}>{messages.executiveLevel[value]}</button>)}
      </div>
      <div className="workspace-zoom" role="group" aria-label={messages.scheduleZoom}>
        {zoomLevels.map((value) => <button key={value} type="button" aria-pressed={zoom === value}
          onClick={() => setZoom(value)}>{messages.executiveZoom[value]}</button>)}
      </div>
      <label><input type="checkbox" checked={showArchived} onChange={(event) => {
        const checked = event.target.checked;
        setShowArchived(checked);
        if (!checked && products.find((product) => product.id === productFilter)?.active === false) {
          setProductFilter(""); setDisciplineFilter("");
        }
      }} />
        {messages.executiveShowArchived}</label>
      <label><input type="checkbox" checked={showTargets} onChange={(event) => setShowTargets(event.target.checked)} />
        {messages.executiveShowTargets}</label>
      <button type="button" className="back-button executive-full__refresh" onClick={() => void load()}>
        {messages.executiveRefresh}</button>
    </div>
    <div className="executive-full__filters" role="group" aria-label={messages.executiveFilters}>
      <label htmlFor="executive-product-filter">{messages.executiveProductFilter}</label>
      <select id="executive-product-filter" value={productFilter} onChange={(event) => {
        setProductFilter(event.target.value); setDisciplineFilter(""); }}>
        <option value="">{messages.executiveAllProducts}</option>
        {productOptions.map((product) => <option key={product.id} value={product.id}>{product.name}</option>)}
      </select>
      <label htmlFor="executive-discipline-filter">{messages.executiveDisciplineFilter}</label>
      <select id="executive-discipline-filter" value={disciplineFilter}
        onChange={(event) => setDisciplineFilter(event.target.value)}>
        <option value="">{messages.executiveAllDisciplines}</option>
        {disciplineOptions.map(({ product, discipline }) => <option key={discipline.id} value={discipline.id}>
          {product.name} · {discipline.name}</option>)}
      </select>
      <button type="button" className="back-button" onClick={() => {
        setProductFilter(""); setDisciplineFilter(""); setShowArchived(true);
      }}>{messages.executiveResetFilters}</button>
      <div className="executive-full__expansion-actions">
        <button type="button" className="back-button" disabled={level === "products"} onClick={() => {
          setCollapsedProducts(emptyIds()); setCollapsedDisciplines(emptyIds()); setCollapsedStages(emptyIds());
        }}>{messages.executiveExpandAll}</button>
        <button type="button" className="back-button" disabled={level === "products"}
          onClick={() => setCollapsedProducts(new Set(visibleProducts.map((product) => product.id)))}>
          {messages.executiveCollapseAll}</button>
      </div>
    </div>
    {displayStatus === "loading" && <p role="status">{messages.executiveLoading}</p>}
    {displayStatus === "error" && <div role="alert"><p>{messages.executiveError}</p>
      <button type="button" onClick={() => void load()}>{messages.retry}</button></div>}
    {displayStatus === "ready" && products.length === 0 && <p>{messages.executiveEmpty}</p>}
    {displayStatus === "ready" && products.length > 0 && visibleProducts.length === 0 &&
      <p>{messages.executiveFilteredEmpty}</p>}
    {displayStatus === "ready" && rows.length > 0 && <div className="executive-full__viewport" ref={viewport}
      role="table" aria-label={messages.executiveFullTitle}>
      <div className="executive-full__header" role="row"
        style={{ width: `calc(var(--executive-full-label-width) + ${timeline.width}px)` }}>
        <div className="executive-full__label-head" role="columnheader">{messages.executiveHierarchy}</div>
        <div className="executive-full__timeline-head" role="columnheader" style={{ width: timeline.width }}>
          <div className="executive-full__months">{timeline.months.map((month) => <span key={month.startDay}
            style={{ width: month.days * timeline.dayWidth }}>
            {monthLabel.format(new Date(month.startDay * 86_400_000))}</span>)}</div>
          <div className="executive-full__ticks">{timeline.ticks.map((day) => <span key={day}
            style={{ left: (day - timeline.startDay) * timeline.dayWidth }}>
            {zoom === "month" ? formatCivilDate(civilFromDay(day)).slice(3)
              : formatCivilDate(civilFromDay(day)).slice(0, 5)}</span>)}</div>
          <span className="executive-full__today-head" style={{ left: todayLeft }}
            title={`${messages.today}: ${formatCivilDate(today)}`}>{messages.today}</span>
        </div>
      </div>
      {rows.map((row) => {
        const productMode = level === "products";
        const productStages = productMode ? packExecutiveStages({ ...row.product,
          disciplines: disciplineFilter ? row.product.disciplines.filter((item) => item.id === disciplineFilter)
            : row.product.disciplines }) : null;
        const height = productMode ? Math.max(58, 12 + (productStages?.laneCount ?? 0) * 20 + 24)
          : row.kind === "product" ? 52 : 38;
        const rowLabel = row.kind === "activity" && !row.stage ? messages.executiveRootActivity :
          messages.executiveRowKind[row.kind];
        return <div key={row.key} className={`executive-full__row executive-full__row--${row.kind}${selectedRow === row.key ? " is-selected" : ""}`}
          role="row" aria-selected={selectedRow === row.key} data-row-key={row.key}
          style={{ width: `calc(var(--executive-full-label-width) + ${timeline.width}px)`, height }}
          onClick={() => setSelectedRow(row.key)}>
          <div className="executive-full__label" role="rowheader" style={{ paddingLeft: 12 + row.depth * 18 }}>
            {row.hasChildren ? <button type="button" className="executive-full__collapse"
              aria-label={messages.executiveToggleRow(row.label)} aria-expanded={row.expanded}
              onClick={(event) => { event.stopPropagation(); toggleRow(row); }}>{row.expanded ? "▾" : "▸"}</button>
              : <span className="executive-full__collapse-spacer" aria-hidden="true" />}
            {row.color && <span className="executive-full__swatch" style={{ backgroundColor: row.color }} aria-hidden="true" />}
            <span className="executive-full__label-text" title={row.label}><strong>{row.label}</strong>
              <small>{rowLabel}{row.kind === "product" && (row.start || row.end)
                ? ` · ${formatCivilDate(row.start)} – ${formatCivilDate(row.end)}` : ""}
                {!row.start && !row.end ? ` · ${messages.noDate}` : ""}
                {productMode && productStages?.undated.length ? ` · ${messages.executiveUndatedStages(productStages.undated.length)}` : ""}
                {row.kind === "product" && !row.product.active ? ` · ${messages.archived}` : ""}</small></span>
            {row.kind === "product" && <button type="button" className="executive-full__open-product"
              title={messages.executiveOpenProductSchedule(row.product.name)}
              aria-label={messages.executiveOpenProductSchedule(row.product.name)}
              onClick={(event) => { event.stopPropagation(); onOpenProduct(row.product.id); }}>↗</button>}
          </div>
          <div className="executive-full__chart" role="cell" style={{ width: timeline.width, height }}>
            <div className="executive-full__nonworking" aria-hidden="true">{nonWorking.map((band) =>
              <span key={band.startDay} style={{ left: (band.startDay - timeline.startDay) * timeline.dayWidth,
                width: band.dayCount * timeline.dayWidth }} />)}</div>
            <span className="executive-full__today-line" aria-hidden="true" style={{ left: todayLeft }} />
            {productMode ? <>
              {timelineInterval(timeline, row.start, row.end) && <span className="executive-full__product-range"
                title={messages.executiveFullRowDetail(row.label, formatCivilDate(row.start), formatCivilDate(row.end))}
                style={timelineInterval(timeline, row.start, row.end)!} />}
              {productStages?.stages.map(({ stage, discipline, lane, anchorDate, partial }) => {
                const interval = partial ? null : timelineInterval(timeline, stage.start, stage.end);
                const discrepancyText = stageDateDiscrepancies(stage).map((warning) => warning.boundary === "start"
                  ? messages.stageDateActivityBeforeStart(warning.activityName, formatCivilDate(warning.activityDate),
                    formatCivilDate(warning.stageDate))
                  : messages.stageDateActivityAfterEnd(warning.activityName, formatCivilDate(warning.activityDate),
                    formatCivilDate(warning.stageDate)));
                const title = [messages.executiveStageDetail(stage.displayName?.trim() || stage.code || messages.executiveStageUnavailable,
                  discipline?.name?.trim() || discipline?.shortCode?.trim() || messages.executiveDisciplineUnavailable,
                  formatCivilDate(stage.start), formatCivilDate(stage.end)),
                  stage.dateSource === "planned" ? messages.stageDateSourcePlanned : messages.stageDateSourceDerived,
                  ...discrepancyText].join(". ");
                const barLabel = executiveStageBarLabel(discipline, stage);
                return <span key={stage.id} className={`executive-full__product-stage executive-full__product-stage--${stage.dateSource}${partial ? " is-partial" : ""}`}
                  data-stage-id={stage.id} data-lane={lane} role="img" tabIndex={0} title={title} aria-label={title}
                  data-date-source={stage.dateSource}
                  style={{ left: interval?.left ?? timelinePosition(timeline, anchorDate),
                    top: 11 + lane * 20, width: partial ? 6 : interval?.width ?? 0,
                    backgroundColor: stage.color, color: ganttTextColor(stage.color) }}>
                  {barLabel}</span>;
              })}
            </> : <RowBar row={row} scale={timeline} />}
            {row.kind === "product" && showTargets && <TargetMarkers product={row.product} scale={timeline}
              top={height - 22} onOpen={openTargets} />}
          </div>
        </div>;
      })}
    </div>}
    {targetDialog && displayStatus === "ready" && <div className="executive-full__dialog-backdrop"
      onMouseDown={(event) => { if (event.target === event.currentTarget) closeTargets(); }}>
      <div className="executive-full__dialog" role="dialog" aria-modal="true"
        aria-labelledby="executive-full-target-title" onKeyDown={(event) => {
          if (event.key === "Escape") { event.stopPropagation(); closeTargets(); }
          if (event.key === "Tab") { event.preventDefault(); dialogClose.current?.focus(); }
        }}>
        <div className="executive-full__dialog-heading"><h3 id="executive-full-target-title">
          {messages.executiveTargetsForProduct(targetDialog.product.name)}</h3>
          <button type="button" className="back-button" ref={dialogClose} autoFocus onClick={closeTargets}>
            {messages.executiveCloseDetails}</button></div>
        <ul>{targetDialog.targets.map((target) => <li key={target.id}>
          <span className="executive-full__target-swatch" style={{ backgroundColor: target.color }} aria-hidden="true" />
          <span><strong>{target.name}</strong><small>{formatCivilDate(target.targetDate)}</small>
            {target.description && <span>{target.description}</span>}
            {target.operationalDate && <small>{messages.executiveOperationalDate(formatCivilDate(target.operationalDate))}</small>}</span>
        </li>)}</ul>
      </div>
    </div>}
  </section>;
}
