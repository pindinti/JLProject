import { type FormEvent, useEffect, useRef, useState } from "react";
import { ChangeHistoryDialog } from "./ChangeHistoryDialog";
import { DatePickerField } from "./DatePickerField";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { messages } from "./locales/pt-BR";
import type { PrintDateSegment } from "./print-pagination";
import type { PrintDetail, PrintFit, PrintOptions } from "./schedule-print-options";

export function SchedulePrintDialog({ visibleRange, details, currentDetail, individual, onClose, onPrint }: {
  visibleRange?: PrintDateSegment;
  details: readonly { value: PrintDetail; label: string }[];
  currentDetail: PrintDetail;
  individual?: boolean;
  onClose: () => void;
  onPrint: (options: PrintOptions, acceptWarning: boolean) => boolean;
}) {
  const [detail, setDetail] = useState(currentDetail);
  const [rangeMode, setRangeMode] = useState("complete");
  const [start, setStart] = useState(visibleRange ? formatCivilDate(visibleRange.start) : "");
  const [end, setEnd] = useState(visibleRange ? formatCivilDate(visibleRange.end) : "");
  const [fit, setFit] = useState<PrintFit>("automatic");
  const [showMilestones, setShowMilestones] = useState(true);
  const [showToday, setShowToday] = useState(true);
  const [error, setError] = useState(false);
  const [warning, setWarning] = useState(false);
  const warningRef = useRef<HTMLParagraphElement>(null);
  const submitRef = useRef<HTMLButtonElement>(null);
  const copy = messages.printConfig;
  useEffect(() => {
    if (warning) warningRef.current?.focus();
  }, [warning]);

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const from = parseBrazilianDate(start);
    const to = parseBrazilianDate(end);
    if (rangeMode === "custom" && (!from || !to || from > to)) { setError(true); return; }
    const range = rangeMode === "custom" && from && to ? { start: from, end: to }
      : rangeMode === "visible" ? visibleRange : undefined;
    if (onPrint({ detail, range, fit, showMilestones, showToday }, warning)) onClose();
    else setWarning(true);
  }

  return <ChangeHistoryDialog title={copy.title} closeLabel={messages.cancel} onClose={onClose}
    className="schedule-print-dialog" footer={<div className="schedule-print-dialog__actions">
      {warning && <button type="button" className="jl-button jl-button--secondary" onClick={() => { setWarning(false); submitRef.current?.focus(); }}>{copy.change}</button>}
      <button type="button" className="jl-button jl-button--secondary" onClick={onClose}>{messages.cancel}</button>
      <button ref={submitRef} type="submit" form="schedule-print-options" className="jl-button jl-button--primary">{warning ? copy.proceed : copy.submit}</button>
    </div>}>
    <p className="schedule-print-dialog__paper-summary">{copy.paperSummary}</p>
    <form id="schedule-print-options" onSubmit={submit} onChange={() => setError(false)}>
      <fieldset disabled={warning}>
        {individual && <label className="schedule-print-dialog__field">{copy.version}<select disabled aria-describedby="print-version-availability">
          <option>{messages.printLivingSchedule}</option>
        </select><small id="print-version-availability">{copy.revisionsUnavailable}</small></label>}
        <label className="schedule-print-dialog__field">{copy.detail}<select value={detail} onChange={(event) => setDetail(event.target.value as PrintDetail)}>
          {details.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </select></label>
        <label className="schedule-print-dialog__field">{copy.range}<select value={rangeMode} onChange={(event) => setRangeMode(event.target.value)}>
          <option value="complete">{copy.complete}</option>
          <option value="visible" disabled={!visibleRange}>{copy.visible}</option>
          <option value="custom">{copy.custom}</option>
        </select></label>
        {rangeMode === "custom" && <div className="schedule-print-dialog__dates">
          <div><label htmlFor="print-custom-start">{messages.productHistoryStart}</label>
            <DatePickerField id="print-custom-start" label={messages.productHistoryStart} value={start}
              onChange={setStart} portalWithinDialog /></div>
          <div><label htmlFor="print-custom-end">{messages.productHistoryEnd}</label>
            <DatePickerField id="print-custom-end" label={messages.productHistoryEnd} value={end}
              onChange={setEnd} portalWithinDialog /></div>
        </div>}
        {error && <p role="alert">{copy.invalidDates}</p>}
        <label className="schedule-print-dialog__field">{copy.fit}<select value={fit} onChange={(event) => setFit(event.target.value as PrintFit)}>
          <option value="automatic">{copy.automatic}</option>
          <option value="width">{copy.width}</option>
          <option value="single">{copy.single}</option>
        </select></label>
        <fieldset className="schedule-print-dialog__additional">
          <legend>{copy.additionalElements}</legend>
          <label className="schedule-print-dialog__check"><input type="checkbox" checked={showMilestones} onChange={(event) => setShowMilestones(event.target.checked)} />
            <span>{messages.printMilestones}</span></label>
          <label className="schedule-print-dialog__check"><input type="checkbox" checked={showToday} onChange={(event) => setShowToday(event.target.checked)} />
            <span>{copy.today}</span></label>
          <div className="schedule-print-dialog__unavailable">
            <label className="schedule-print-dialog__check"><input type="checkbox" disabled aria-describedby="print-dependency-availability" />
              <span>{copy.dependencies}</span></label>
            <small id="print-dependency-availability">{copy.dependenciesUnavailable}</small>
          </div>
        </fieldset>
      </fieldset>
      {warning && <p ref={warningRef} role="alert" tabIndex={-1}>{copy.readability}</p>}
    </form>
  </ChangeHistoryDialog>;
}
