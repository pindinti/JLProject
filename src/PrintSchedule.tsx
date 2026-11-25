import { useLayoutEffect, useRef, useState } from "react";
import { civilFromDay, dayNumber } from "../domain/schedule-workspace";
import { formatCivilDate } from "./civil-date";
import { schedulePrintTitle } from "./print-dialog";
import { ganttTextColor } from "./design/gantt-colors";
import { messages } from "./locales/pt-BR";
import { paginatePrintRows, planPrintTimeline, selectPrintRows, type PrintDateSegment, type PrintRow } from "./print-pagination";
import { layoutPrintStageLabels, printDisciplineAbbreviations, printStageIdentities } from "./print-stage-labels";
import type { PrintFit } from "./schedule-print-options";

export interface PrintableBar {
  key: string;
  label: string;
  discipline?: string;
  disciplineKey?: string;
  stageCode?: string | null;
  stageName?: string | null;
  start: string | null;
  end: string | null;
  color: string;
  lane: number;
  dateSource?: "planned" | "derived";
}

export interface PrintableScheduleRow extends PrintRow {
  label: string;
  kind: string;
  depth: number;
  start: string | null;
  end: string | null;
  color?: string | null;
  dateSource?: "planned" | "derived";
  bars?: readonly PrintableBar[];
  milestones?: readonly PrintableMilestone[];
}
export interface PrintableMilestone { id: string; name: string; date: string; color: string }

const standardTimelineWidth = 268; // 400 mm content less 92 mm hierarchy and two 20 mm date columns.
const rowSpace = 222; // The rest of the content box is reserved for document furniture and rounding.
const mm = (value: number) => `${value}mm`;
const indent = (row: PrintableScheduleRow) => Math.min(18, row.depth * 3);

// Conservative first pass for rows before browser layout is available.
function textLines(text: string, width: number) {
  const limit = Math.max(1, Math.floor(width / 2.8));
  return Math.max(1, text.split("\n").reduce((lines, part) => {
    let count = 1;
    let used = 0;
    for (const word of part.split(/\s+/)) {
      if (used && used + word.length + 1 > limit) { count++; used = 0; }
      const length = word.length;
      if (length > limit) count += Math.ceil(length / limit) - 1;
      used = (used ? used + 1 : 0) + ((length - 1) % limit + 1);
    }
    return lines + count;
  }, 0));
}

function measurePrintDocument(document: HTMLElement) {
  const pxToMm = 25.4 / 96;
  const roundedUp = (px: number) => Math.ceil(px * pxToMm * 100) / 100;
  const spaces = new Map<string, number>();
  const heights = new Map<string, Map<string, number>>();
  const eventHeights = new Map<string, number>();
  for (const page of document.querySelectorAll<HTMLElement>(".print-page[data-interval]")) {
    const interval = page.dataset.interval!;
    const head = page.querySelector(".print-table__head")?.getBoundingClientRect();
    const foot = page.querySelector(".print-page__footer")?.getBoundingClientRect();
    if (!head?.height || !foot?.height) continue;
    const occupied = head.bottom - page.getBoundingClientRect().top + foot.height;
    // 296.5 mm sheet wrapper, less the bottom inset and a layout rounding allowance.
    const space = 285.5 - roundedUp(occupied);
    if (space > 0) spaces.set(interval, Math.min(space, spaces.get(interval) ?? space));
    const measuredRows = heights.get(interval) ?? new Map<string, number>();
    for (const row of page.querySelectorAll<HTMLElement>("[data-print-row]")) {
      const height = roundedUp(row.getBoundingClientRect().height);
      if (height > 0) measuredRows.set(row.dataset.printRow!, height);
    }
    heights.set(interval, measuredRows);
    for (const label of page.querySelectorAll<HTMLElement>("[data-print-event]")) {
      const height = roundedUp(label.getBoundingClientRect().height);
      if (height > 0) eventHeights.set(label.dataset.printEvent!, height);
    }
  }
  if (!spaces.size) return undefined;
  const canvas = typeof CanvasRenderingContext2D !== "undefined" && document.querySelector(".print-stage")
    ? document.ownerDocument.createElement("canvas").getContext("2d") : null;
  if (canvas) canvas.font = `8pt ${getComputedStyle(document).fontFamily}`;
  return { spaces, heights, eventHeights,
    measureStage: canvas ? (text: string) => canvas.measureText(text).width * pxToMm : undefined };
}

function dateGeometry(segment: PrintDateSegment, mmPerDay: number) {
  const start = dayNumber(segment.start);
  const end = dayNumber(segment.end) + 1;
  const position = (date: string) => (dayNumber(date) - start + 0.5) * mmPerDay;
  const contains = (date: string) => date >= segment.start && date <= segment.end;
  function bar(startDate: string | null, endDate: string | null) {
    if (!startDate || !endDate) {
      const anchor = startDate ?? endDate;
      return anchor && contains(anchor) ? { left: position(anchor), width: 0, partial: true } : null;
    }
    const left = Math.max(start, dayNumber(startDate));
    const right = Math.min(end, dayNumber(endDate) + 1);
    return right > left ? { left: (left - start) * mmPerDay, width: (right - left) * mmPerDay, partial: false } : null;
  }
  const ticks: { left: number; center: number; label: string; short: boolean }[] = [];
  for (let first = start; first < end;) {
    const date = civilFromDay(first);
    let next = first + 1;
    while (next < end && !civilFromDay(next).endsWith("-01")) next++;
    const left = (first - start) * mmPerDay;
    const width = (next - first) * mmPerDay;
    ticks.push({ left, center: left + width / 2, short: width < 10,
      label: `${date.slice(5, 7)}/${date.slice(0, 4)}` });
    first = next;
  }
  return { contains, position, bar, ticks };
}

function layoutEvents(items: readonly PrintableMilestone[], position: (date: string) => number,
  timelineWidth: number, measured?: Map<string, number>) {
  const lanes: { right: number; height: number }[] = [];
  const labels = items.map((item) => {
    const marker = position(item.date);
    const text = `${item.name} · ${formatCivilDate(item.date)}`;
    const width = Math.max(34, Math.min(76, text.length * 1.5 + 3));
    return { ...item, marker, width, left: Math.min(marker, timelineWidth - width), text };
  }).sort((a, b) => a.left - b.left || a.marker - b.marker).map((item) => {
    let lane = lanes.findIndex((entry) => entry.right + 1 <= item.left);
    if (lane < 0) lane = lanes.length;
    const height = (measured?.get(item.id) ?? textLines(item.text, item.width - 2) * 3.25 + 1.1) + 0.35;
    lanes[lane] = { right: item.left + item.width, height: Math.max(height, lanes[lane]?.height ?? 0) };
    return { ...item, lane };
  });
  let used = 0;
  const offsets = lanes.map(({ height }) => {
    const top = used;
    if (top + height > 46) return null;
    used += height;
    return top;
  });
  const hasOverflow = offsets.includes(null);
  const markers = new Map<string, { left: number; color: string; spilled: boolean }>();
  for (const item of labels) {
    const previous = markers.get(item.date);
    markers.set(item.date, { left: item.marker, color: previous ? "#52694D" : item.color,
      spilled: Boolean(previous?.spilled || offsets[item.lane] === null) });
  }
  return { labels, offsets, markers: [...markers.values()], height: used + (hasOverflow ? 5 : 0) };
}

interface StagePrintSpace {
  width: number;
  executiveProducts: boolean;
  markerPositions: readonly number[];
  rowEvents?: ReturnType<typeof layoutEvents>;
  eventOverflowOnContinuation?: boolean;
}

function abbreviationKey(rows: readonly { abbreviations: ReadonlyMap<string, string> }[]) {
  return [...new Map(rows.flatMap(({ abbreviations }) => [...abbreviations]))]
    .map(([short, name]) => `${short} = ${name}`).join(" · ");
}

function abbreviationKeyHeight(rows: readonly { abbreviations: ReadonlyMap<string, string> }[]) {
  const key = abbreviationKey(rows);
  return key ? textLines(`${messages.printDisciplineKey}: ${key}`, 394) * 3.4 + 2 : 0;
}

function preparePrintRow(row: PrintableScheduleRow, geometry: ReturnType<typeof dateGeometry>,
  identities: ReturnType<typeof printStageIdentities<PrintableBar>>, references: ReadonlyMap<PrintableBar, number>,
  measure: (text: string) => number, space: StagePrintSpace) {
  const plots = (row.bars ?? []).flatMap((item) => {
    const box = geometry.bar(item.start, item.end);
    return box ? [{ ...item, ...box, labels: identities.get(item) ?? [], reference: references.get(item)! }] : [];
  });
  const { bars: plotted, height: stageHeight } = layoutPrintStageLabels(plots, space.width, measure,
    space.markerPositions, space.executiveProducts);
  const abbreviations = new Map<string, string>();
  for (const bar of plotted) {
    const abbreviation = (bar.inside ?? bar.outside)?.abbreviation;
    if (abbreviation && bar.discipline) abbreviations.set(abbreviation, bar.discipline);
  }
  const notes = plotted.filter((bar) => bar.badge).map(({ label, start, end, reference }) => {
    const dates = start && end ? [...new Set([start, end])].map(formatCivilDate).join(" – ")
      : `${start ? messages.productHistoryStart : messages.productHistoryEnd}: ${formatCivilDate(start ?? end)}`;
    return { reference: `#${reference}`, label: `${label} (${dates})` };
  });
  const undated = (row.bars ?? []).filter(({ start, end }) => !start && !end).map(({ label }) => label);
  const legend = [...abbreviations].map(([short, name]) => `${short} = ${name}`).join(" · ");
  const noteLines = [
    space.executiveProducts ? "" : legend,
    notes.map(({ reference, label }) => `${reference} ${label}`).join(" · "),
    undated.length ? `${messages.printUndatedStages}: ${undated.join(" · ")}` : "",
  ].filter(Boolean);
  const rowEvents = space.rowEvents;
  const overflowEvents = space.eventOverflowOnContinuation ? [] :
    rowEvents?.labels.filter(({ lane }) => rowEvents.offsets[lane] === null) ?? [];
  if (overflowEvents.length) noteLines.push(`+ ${messages.printMilestones}: ${overflowEvents
    .map(({ name, date }) => `${name} · ${formatCivilDate(date)}`).join(" · ")}`);
  const heightUnits = Math.ceil(Math.max(
    textLines(row.label, (space.executiveProducts ? 56 : 85) - indent(row)) * 3.8 +
      (space.executiveProducts ? 5.1 : 1.7),
    (rowEvents?.height ?? 0) + Math.max(4.5, stageHeight + 1) + 0.5,
    5.5,
  ) + noteLines.reduce((height, line) => height + textLines(line, space.executiveProducts ? 394 : space.width - 6) * 3.4, 0)
    + (space.executiveProducts && noteLines.length ? 1.5 : 0));
  return { ...row, plotted, stageHeight, notes, undated, legend, abbreviations, rowEvents, overflowEvents, heightUnits,
    eventOverflowOnContinuation: space.eventOverflowOnContinuation };
}

function preparePrintRows(row: PrintableScheduleRow, geometry: ReturnType<typeof dateGeometry>,
  identities: ReturnType<typeof printStageIdentities<PrintableBar>>, references: ReadonlyMap<PrintableBar, number>,
  measure: (text: string) => number, space: StagePrintSpace, capacity: number,
  heights?: Map<string, number>): ReturnType<typeof preparePrintRow>[] {
  const prepared = preparePrintRow(row, geometry, identities, references, measure, space);
  // Adaptation can change the stage lanes between the provisional and measured passes.
  if (!row.bars?.length && !space.rowEvents) prepared.heightUnits = heights?.get(row.key) ?? prepared.heightUnits;
  const keyHeight = space.executiveProducts ? abbreviationKeyHeight([prepared]) : 0;
  if (prepared.heightUnits + keyHeight <= capacity || !row.bars || row.bars.length < 2) return [prepared];
  const middle = Math.ceil(row.bars.length / 2);
  // Packed bars belong to a product overview row. Repeat the product when the bar stack cannot fit one sheet.
  const first = row.bars.slice(0, middle);
  const rest = row.bars.slice(middle);
  const tailSpace = space.rowEvents ? { ...space, rowEvents: { ...space.rowEvents, labels: [], height: 0 } } : space;
  return [first, rest].flatMap((bars, index) => preparePrintRows({
    ...row, key: `${row.key}:continued:${bars[0].key}:${bars.at(-1)!.key}`, bars,
  }, geometry, identities, references, measure, index === 0 ? space : tailSpace, capacity, heights));
}

function eventContinuationRows(items: readonly (PrintableMilestone & { markerReference: string })[]) {
  return items.map((item) => ({ ...item, key: item.id, heightUnits: Math.ceil(textLines(item.name, 320) * 3.8 + 2) }));
}

export function PrintSchedule({ title, detail, rows, milestones, startDate, endDate, today, executive = false, executiveProducts = false,
  fit = "automatic", showToday = true, showMilestones = true }: {
  title: string; detail?: string; rows: PrintableScheduleRow[]; milestones: PrintableMilestone[];
  startDate?: string; endDate?: string; today: string; executive?: boolean; executiveProducts?: boolean;
  fit?: PrintFit; showToday?: boolean; showMilestones?: boolean;
}) {
  const printRoot = useRef<HTMLDivElement>(null);
  const [measurements, setMeasurements] = useState<ReturnType<typeof measurePrintDocument>>();
  useLayoutEffect(() => {
    if (printRoot.current) setMeasurements(measurePrintDocument(printRoot.current));
  }, []);
  const timelineWidth = executiveProducts ? 340 : standardTimelineWidth;
  const sourceDates = [...rows.flatMap((row) => [
    ...[row, ...(row.bars ?? [])].flatMap(({ start, end }) => [start, end]),
    ...(showMilestones ? (row.milestones ?? []).map(({ date }) => date) : []),
  ]),
    ...(showMilestones ? milestones.map(({ date }) => date) : [])]
    .filter((date): date is string => Boolean(date)).sort();
  const from = startDate ?? sourceDates[0] ?? today;
  const to = endDate ?? sourceDates.at(-1) ?? today;
  const automatic = planPrintTimeline(from, to, timelineWidth);
  const single = fit === "single";
  const segments = fit === "automatic" ? automatic.segments : [{ start: from, end: to }];
  const mmPerDay = fit === "automatic" ? automatic.mmPerDay : timelineWidth / (dayNumber(to) - dayNumber(from) + 1);
  const selections = selectPrintRows(rows, segments, !executiveProducts, showMilestones);
  const allStages = rows.flatMap((row) => row.bars ?? []);
  const aliases = printDisciplineAbbreviations(allStages.flatMap((bar) => bar.discipline ? [bar.discipline] : []));
  const identities = new Map(rows.map((row) => [row.key, printStageIdentities(row.bars ?? [], aliases, executiveProducts)]));
  const references = new Map(allStages.filter((bar) => bar.start || bar.end).map((bar, index) => [bar, index + 1]));
  const measure = measurements?.measureStage ?? ((text: string) => text.length * 2.8);
  const visibleMilestones = showMilestones ? milestones : [];
  const outsideEvents = visibleMilestones.filter(({ date }) => date < from || date > to);
  const notedUndatedRows = new Set<string>();
  const headerExtra = Math.max(0, textLines(title, 200) - 1) * 6 +
    Math.max(0, textLines(detail ?? "", 250) - 1) * 4;
  const pages = segments.flatMap((interval, index) => {
    const geometry = dateGeometry(interval, mmPerDay);
    const events = layoutEvents(visibleMilestones.filter(({ date }) => geometry.contains(date)),
      geometry.position, timelineWidth, measurements?.eventHeights);
    const todayPosition = showToday && geometry.contains(today) ? geometry.position(today) : null;
    const hasShortMonth = fit === "automatic" && geometry.ticks.some((tick) => tick.short);
    const extraTracks = (hasShortMonth ? 3.25 : 0) + (todayPosition === null ? 0 : 3.25);
    const rowCapacity = measurements?.spaces.get(interval.start) ?? rowSpace - headerExtra - extraTracks;
    const capacity = single ? Infinity : Math.floor(rowCapacity - events.height);
    const space = { width: timelineWidth, executiveProducts,
      markerPositions: executiveProducts ? [...events.markers.map(({ left }) => left),
        ...(todayPosition === null ? [] : [todayPosition])] : [] };
    const ownedContinuations: { owner: string; rows: ReturnType<typeof eventContinuationRows> }[] = [];
    const prepared = selections[index].flatMap((row) => {
      const includeUndated = !notedUndatedRows.has(row.key);
      notedUndatedRows.add(row.key);
      const bars = row.bars?.filter(({ start, end }) => Boolean(geometry.bar(start, end)) ||
        includeUndated && !start && !end);
      const owned = showMilestones ? row.milestones?.filter(({ date }) => geometry.contains(date)) : undefined;
      if (showMilestones && includeUndated && (startDate || endDate)) {
        const outside = row.milestones?.filter(({ date }) => date < from || date > to);
        if (outside?.length) ownedContinuations.push({ owner: row.label,
          rows: eventContinuationRows(outside.map((item) => ({ ...item, markerReference: messages.printConfig.outsideRange }))) });
      }
      const rowEvents = owned?.length ? layoutEvents(owned, geometry.position, timelineWidth, measurements?.eventHeights)
        : undefined;
      const scoped: StagePrintSpace = rowEvents ? { ...space, rowEvents,
        markerPositions: [...space.markerPositions, ...rowEvents.markers.map(({ left }) => left)] } : space;
      const printable = { ...row, bars };
      const rowIdentities = identities.get(row.key)!;
      if (rowEvents?.offsets.includes(null)) {
        const proposed = preparePrintRow(printable, geometry, rowIdentities, references, measure, scoped);
        if (proposed.heightUnits + (executiveProducts ? abbreviationKeyHeight([proposed]) : 0) > capacity) {
          ownedContinuations.push({ owner: row.label,
            rows: eventContinuationRows(proposed.overflowEvents.map((item) => ({ ...item, markerReference: "+" }))) });
          scoped.eventOverflowOnContinuation = true;
        }
      }
      return preparePrintRows(printable, geometry, rowIdentities, references, measure, scoped, capacity,
        measurements?.heights.get(interval.start));
    });
    const overflow = events.labels.filter((item) => events.offsets[item.lane] === null).map((item) =>
      ({ ...item, markerReference: "+" }));
    const eventRows = eventContinuationRows([
      ...overflow,
      ...(index === 0 ? outsideEvents.map((item) => ({ ...item, markerReference: messages.printConfig.outsideRange })) : []),
    ]);
    const continuations = [{ owner: undefined, rows: eventRows }, ...ownedContinuations].filter((item) => item.rows.length);
    if (single) return [{ interval, geometry, events, pageRows: prepared, todayPosition, hasShortMonth, extraTracks,
      continuedEvents: [] as typeof eventRows, eventOwner: undefined, inlineContinuations: continuations }];
    const rowPages = paginatePrintRows(prepared, capacity, executiveProducts ? abbreviationKeyHeight : undefined);
    return [
      ...(rowPages.length ? rowPages : events.labels.length ? [[]] : []).map((pageRows) =>
        ({ interval, geometry, events, pageRows, todayPosition, hasShortMonth, extraTracks,
          continuedEvents: [] as typeof eventRows, eventOwner: undefined as string | undefined,
          inlineContinuations: [] as typeof continuations })),
      ...continuations.flatMap(({ owner, rows }) =>
        paginatePrintRows(rows, Math.floor(rowSpace - headerExtra - (owner ? 6 : 0))).map((continuedEvents) =>
          ({ interval, geometry, events, pageRows: [] as typeof prepared, todayPosition, hasShortMonth, extraTracks,
            continuedEvents, eventOwner: owner, inlineContinuations: [] as typeof continuations }))),
    ];
  });
  const issued = formatCivilDate(today);
  return <div className="print-document" ref={printRoot}
    data-print-title={schedulePrintTitle(issued, executive ? undefined : title)}
    data-print-density-warning={fit !== "automatic" && automatic.segments.length > 1}>
    {pages.map(({ interval, geometry, events, pageRows, continuedEvents, eventOwner, todayPosition, hasShortMonth, extraTracks,
      inlineContinuations }, index) => {
      const guides = (showSpill: boolean, tracks?: readonly { top: number; height: number }[],
        rowEvents?: ReturnType<typeof layoutEvents>) =>
        <div className="print-table__guides" aria-hidden="true">
        {(executiveProducts || !rowEvents) && geometry.ticks.map((tick) =>
          <i key={tick.left} className="print-table__tick" style={{ left: mm(tick.left) }} />)}
        {(tracks ?? [null]).map((track) => {
          const bounds = track ? { top: mm(track.top), height: mm(track.height), bottom: "auto" } : {};
          return <div key={track?.top ?? "full"}>
            {(rowEvents ?? events).markers.map((marker) => <i key={marker.left} className="print-table__marker"
              style={{ ...bounds, left: mm(marker.left), borderColor: marker.color }}>{showSpill && marker.spilled && <b>+</b>}</i>)}
            {(executiveProducts || !rowEvents) && todayPosition !== null &&
              <i className="print-table__today" style={{ ...bounds, left: mm(todayPosition) }} />}
          </div>;
        })}
      </div>;
      const eventBand = (band: ReturnType<typeof layoutEvents>, owned = false, continued = false) =>
        band.height > 0 && <div className="print-event-band" style={{ height: mm(band.height) }}>
          {band.markers.map((marker) => <i key={marker.left} className="print-event__guide" aria-hidden="true"
            style={{ left: mm(marker.left), borderColor: marker.color }}>
            {(owned || executiveProducts) && marker.spilled && <b>+</b>}
          </i>)}
          {todayPosition !== null && <i className="print-table__today" aria-hidden="true" style={{ left: mm(todayPosition) }} />}
          {band.labels.map((item) => {
            const top = band.offsets[item.lane];
            return top === null ? null : <div className="print-event" key={item.id} data-print-event={item.id}
              style={{ top: mm(top), left: mm(item.left), width: mm(item.width), borderColor: item.color }}>
              <i style={{ left: mm(item.marker - item.left), backgroundColor: item.color }} aria-hidden="true" />
              <span>{item.name}</span> · {formatCivilDate(item.date)}
            </div>;
          })}
          {(!owned || continued) && band.offsets.includes(null) &&
            <div className="print-table__references">+ {messages.printMilestonesContinued}</div>}
        </div>;
      const pageKey = executiveProducts ? abbreviationKey(pageRows) : "";
      const renderContinuation = (items: typeof continuedEvents, owner?: string) =>
        <div className="print-event-continuation" key={items[0]?.key}>
          <h2>{messages.printMilestones}{owner && ` — ${owner}`}</h2>
          {items.map((item) => <div key={item.key} className={item.markerReference === messages.printConfig.outsideRange
            ? "print-event-outside-range" : undefined}>
            <i style={{ backgroundColor: item.color }} aria-hidden="true" />
            <span>{item.markerReference} · {formatCivilDate(item.date)}</span><strong>{item.name}</strong>
          </div>)}
        </div>;
      let lastTick = -Infinity;
      const content = <>
        <header className="print-page__header">
          <img src="/brand/jlproject-logo.svg" alt="JLProject" />
          <div><h1>{title}</h1>{detail && <p>{detail}</p>}
            <p>{messages.printIssued}: {issued}</p></div>
        </header>
        <div className="print-page__range">
          {pageRows.some((row) => row.dateSource || row.plotted.some((bar) => bar.dateSource)) &&
            <div className="print-stage-legend">
              <span data-date-source="planned">{messages.stageDateSourcePlanned}</span>
              <span data-date-source="derived">{messages.stageDateSourceDerived}</span>
            </div>}
          <span>{formatCivilDate(interval.start)} – {formatCivilDate(interval.end)}</span>
        </div>
        {continuedEvents.length ? renderContinuation(continuedEvents, eventOwner) :
          <div className={`print-table${executiveProducts ? " print-table--executive-products" : ""}`}>
          <div className="print-table__head" style={{ minHeight: mm(7 + extraTracks) }}>
            <strong>{executiveProducts ? messages.executiveProductFilter : messages.printHierarchy}</strong>
            {!executiveProducts && <><strong>{messages.productHistoryStart}</strong>
              <strong>{messages.productHistoryEnd}</strong></>}
            <div className="print-table__timeline" aria-label={messages.scheduleTimeline}>
              {geometry.ticks.map((tick) => {
                const short = fit === "automatic" && tick.short;
                const x = fit !== "automatic" || short ? Math.min(timelineWidth - 6, Math.max(6, tick.center)) : tick.center;
                if (fit !== "automatic" && x - lastTick < 10) return null;
                lastTick = x;
                return <span key={tick.left} className={short ? "print-table__month--edge" : undefined}
                  style={{ left: mm(x) }}>{tick.label}</span>;
              })}
              {todayPosition !== null && <span className="print-table__today-label"
                style={{ left: mm(Math.min(timelineWidth - 4, Math.max(4, todayPosition))), top: mm(hasShortMonth ? 8 : 4.75) }}>
                {messages.today}
              </span>}
            </div>
          </div>
          {eventBand(events)}
          <div className="print-table__rows">
            {!executiveProducts && guides(true)}
            {pageRows.map((row, rowIndex) => {
              const range = executiveProducts ? null : geometry.bar(row.start, row.end);
              const referenceLanes = executiveProducts ? [...new Set(row.plotted
                .filter((bar) => bar.badge).map((bar) => bar.top))] : [];
              let guideStart = 0;
              const guideTracks = referenceLanes.map((top) => {
                const track = { top: guideStart, height: top + 4.25 - guideStart };
                guideStart = top + 10;
                return track;
              });
              if (referenceLanes.length) guideTracks.push({ top: guideStart, height: row.stageHeight + 1 - guideStart });
              const supplementary = ((!executiveProducts && row.legend) || row.notes.length > 0 ||
                row.undated.length > 0 || row.overflowEvents.length > 0) &&
                <div className="print-table__bar-notes">
                  {!executiveProducts && row.legend && <div>{messages.printDisciplineKey}: {row.legend}</div>}
                  {row.notes.length > 0 && <div>{row.notes.map(({ reference, label }, index) =>
                    <span key={reference}>{index > 0 ? " · " : ""}<strong>{reference}</strong> {label}</span>)}</div>}
                  {row.undated.length > 0 && <div>{messages.printUndatedStages}: {row.undated.join(" · ")}</div>}
                  {row.overflowEvents.length > 0 && <div>+ {messages.printMilestones}: {row.overflowEvents.map(
                    ({ id, name, date, color }, index) => <span key={id}>{index > 0 ? " · " : ""}
                      <i className="print-event-swatch" style={{ backgroundColor: color }} aria-hidden="true" />
                      {name} · {formatCivilDate(date)}</span>)}</div>}
                </div>;
              return <div className={`print-table__row print-table__row--${row.kind}`} data-print-row={row.key} key={`${row.key}:${rowIndex}`}>
                <div className="print-table__label" style={{ paddingLeft: mm(1 + indent(row)) }}>
                  {!executiveProducts && row.color && <i style={{ backgroundColor: row.color }} aria-hidden="true" />}
                  <strong>{row.label}</strong>
                  {executiveProducts && <small>{row.start ? formatCivilDate(row.start) : "—"} – {row.end ? formatCivilDate(row.end) : "—"}</small>}
                </div>
                {!executiveProducts && <><div className="print-table__date">{row.start ? formatCivilDate(row.start) : "—"}</div>
                  <div className="print-table__date">{row.end ? formatCivilDate(row.end) : "—"}</div></>}
                <div className="print-table__chart">
                  {row.rowEvents && eventBand(row.rowEvents, true, row.eventOverflowOnContinuation)}
                  <div className="print-table__bars" style={{ minHeight: mm(row.stageHeight + 1) }}>
                    {(executiveProducts || row.rowEvents) &&
                      guides(false, guideTracks.length ? guideTracks : undefined, row.rowEvents)}
                    {range && <span className={range.partial ? "print-table__boundary" : "print-table__bar"}
                      data-date-source={row.dateSource}
                      style={{ left: mm(range.left), width: mm(range.width),
                        backgroundColor: range.partial ? undefined : row.color ?? "#52694D",
                        borderColor: range.partial ? row.color ?? "#52694D" : undefined,
                        color: ganttTextColor(row.color ?? "#52694D") }} />}
                    {row.plotted.map((bar, index) => {
                      const previous = row.plotted[index - 1];
                      const startsGroup = executiveProducts && previous && previous.disciplineKey !== bar.disciplineKey;
                      const seam = previous && previous.top === bar.top && previous.color === bar.color &&
                        !previous.partial && !bar.partial && Math.abs(previous.left + previous.width - bar.left) < 0.0001;
                      return <div className="print-stage" key={bar.key}>
                      {startsGroup && <i className="print-stage__group-rule" aria-hidden="true" style={{ top: mm(bar.top) }} />}
                      <span className={bar.partial ? "print-table__boundary" : "print-table__bar print-table__bar--stage"}
                        data-date-source={bar.dateSource}
                        style={{ left: mm(bar.left), width: mm(bar.width),
                          backgroundColor: bar.partial ? undefined : bar.color, borderColor: bar.partial ? bar.color : undefined,
                          color: ganttTextColor(bar.color), top: mm(bar.top + 0.5) }}>
                        {bar.inside?.text}
                      </span>
                      {seam && <i className="print-stage__seam" aria-hidden="true"
                        style={{ left: mm(bar.left), top: mm(bar.top + 0.5) }} />}
                      {bar.outside && <>
                        <i className="print-stage__leader" aria-hidden="true"
                          style={{ left: mm(bar.outside.leaderLeft), top: mm(bar.top + 2.5) }} />
                        <span className="print-stage__callout"
                          style={{ left: mm(bar.outside.left), width: mm(bar.outside.width), top: mm(bar.top + 0.5) }}>
                          {bar.outside.text}
                        </span>
                      </>}
                      {bar.badge && <span className="print-stage__badge"
                        style={{ left: mm(bar.badge.left), width: mm(bar.badge.width), top: mm(bar.top + 6.5) }}>
                        #{bar.reference}
                      </span>}
                      </div>;
                    })}
                    {row.plotted.some((bar) => bar.badge) &&
                      <svg className="print-stage__reference-leaders" aria-hidden="true"
                        style={{ height: mm(row.stageHeight + 1) }} viewBox={`0 0 ${timelineWidth} ${row.stageHeight + 1}`}>
                        {row.plotted.map((bar) => bar.badge && <line key={bar.key}
                          x1={bar.badge.anchor} y1={bar.top + 4.25}
                          x2={bar.badge.left + bar.badge.width / 2} y2={bar.top + 6.5} />)}
                      </svg>}
                  </div>
                  {!executiveProducts && supplementary}
                </div>
                {executiveProducts && supplementary}
              </div>;
            })}
          </div>
          {pageKey && <div className="print-executive-key">{messages.printDisciplineKey}: {pageKey}</div>}
        </div>}
        {inlineContinuations.map(({ rows, owner }) => renderContinuation(rows, owner))}
        <footer className="print-page__footer"><span>JLProject · {title}</span>
          <span>{messages.printPage(index + 1, pages.length)}</span></footer>
      </>;
      return <article className={`print-page${single ? " print-page--single" : ""}`} data-interval={interval.start} key={index}>
        {single ? <div className="print-single-content">{content}</div> : content}
      </article>;
    })}
  </div>;
}
