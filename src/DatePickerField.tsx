import { createPortal } from "react-dom";
import { type KeyboardEvent as ReactKeyboardEvent, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { formatCivilDate, parseBrazilianDate } from "./civil-date";
import { messages } from "./locales/pt-BR";

interface DatePickerFieldProps {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
  required?: boolean;
  ariaRequired?: boolean;
  maxLength?: number;
  describedBy?: string;
}

interface CivilParts { year: number; month: number; day: number }
interface PopupPosition { left: number; top: number }

const popupWidth = 288;
const popupHeight = 360;
const weekdayFormatter = new Intl.DateTimeFormat("pt-BR", { weekday: "short", timeZone: "UTC" });
const monthFormatter = new Intl.DateTimeFormat("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
const fullDateFormatter = new Intl.DateTimeFormat("pt-BR", { dateStyle: "full", timeZone: "UTC" });

function utcDate(year: number, monthIndex: number, day: number): Date {
  const date = new Date(0);
  date.setUTCHours(0, 0, 0, 0);
  date.setUTCFullYear(year, monthIndex, day);
  return date;
}

function civilIso(year: number, monthIndex: number, day: number): string {
  const date = utcDate(year, monthIndex, day);
  return `${String(date.getUTCFullYear()).padStart(4, "0")}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")}`;
}

function partsFromIso(value: string): CivilParts | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  return { year: Number(match[1]), month: Number(match[2]), day: Number(match[3]) };
}

function daysInMonth(year: number, monthIndex: number): number {
  return utcDate(year, monthIndex + 1, 0).getUTCDate();
}

function dateForParts(parts: CivilParts): Date {
  return utcDate(parts.year, parts.month - 1, parts.day);
}

function shiftMonth(parts: CivilParts, amount: number): CivilParts {
  const date = utcDate(parts.year, parts.month - 1 + amount, 1);
  const year = Math.min(9999, Math.max(1, date.getUTCFullYear()));
  const month = year === date.getUTCFullYear() ? date.getUTCMonth() + 1 : year === 1 ? 1 : 12;
  return { year, month, day: Math.min(parts.day, daysInMonth(year, month - 1)) };
}

function todayCivil(): CivilParts {
  const today = new Date();
  return { year: today.getFullYear(), month: today.getMonth() + 1, day: today.getDate() };
}

function dateLabel(iso: string): string {
  const parts = partsFromIso(iso);
  return parts ? fullDateFormatter.format(dateForParts(parts)) : iso;
}

function monthLabel(year: number, month: number): string {
  const label = monthFormatter.format(utcDate(year, month - 1, 1));
  return label.replace(/^\p{L}/u, (first) => first.toLocaleLowerCase("pt-BR"));
}

function addDays(iso: string, amount: number): string {
  const parts = partsFromIso(iso);
  if (!parts) return iso;
  const date = dateForParts(parts);
  date.setUTCDate(date.getUTCDate() + amount);
  if (date.getUTCFullYear() < 1 || date.getUTCFullYear() > 9999) return iso;
  return civilIso(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

function clampPopup(trigger: HTMLElement): PopupPosition {
  const rect = trigger.getBoundingClientRect();
  const width = Math.min(popupWidth, Math.max(0, window.innerWidth - 16));
  const left = Math.min(Math.max(8, rect.left), Math.max(8, window.innerWidth - width - 8));
  const below = rect.bottom + 6;
  const preferredTop = below + popupHeight <= window.innerHeight - 8
    ? below : rect.top - popupHeight - 6;
  const top = Math.min(Math.max(8, preferredTop), Math.max(8, window.innerHeight - popupHeight - 8));
  return { left, top };
}

export function DatePickerField({ id, label, value, onChange, disabled = false, required = false, ariaRequired,
  maxLength = 10, describedBy }: DatePickerFieldProps) {
  const wrapperRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popupRef = useRef<HTMLDivElement>(null);
  const activeDayRef = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState<PopupPosition>({ left: 8, top: 8 });
  const initialParts = useMemo(() => {
    const validIso = parseBrazilianDate(value);
    return validIso ? partsFromIso(validIso) : null;
  }, [value]);
  const [view, setView] = useState<CivilParts>(() => initialParts ?? todayCivil());
  const [activeDate, setActiveDate] = useState(() => initialParts
    ? civilIso(initialParts.year, initialParts.month - 1, initialParts.day)
    : civilIso(todayCivil().year, todayCivil().month - 1, todayCivil().day));

  const selectedIso = parseBrazilianDate(value);
  const today = todayCivil();
  const todayIso = civilIso(today.year, today.month - 1, today.day);
  const monthTitle = monthLabel(view.year, view.month);
  const weekDays = useMemo(() => Array.from({ length: 7 }, (_, index) =>
    weekdayFormatter.format(utcDate(2023, 0, 1 + index)).replace(/\.$/, "")), []);
  const gridDates = useMemo(() => {
    const firstWeekday = utcDate(view.year, view.month - 1, 1).getUTCDay();
    const start = utcDate(view.year, view.month - 1, 1);
    start.setUTCDate(start.getUTCDate() - firstWeekday);
    return Array.from({ length: 42 }, (_, index) => {
      const date = new Date(start);
      date.setUTCDate(start.getUTCDate() + index);
      const year = date.getUTCFullYear();
      return year < 1 || year > 9999 ? null : civilIso(year, date.getUTCMonth(), date.getUTCDate());
    });
  }, [view.year, view.month]);

  function openPicker() {
    if (disabled) return;
    const typedDate = parseBrazilianDate(value);
    const base = typedDate ? partsFromIso(typedDate)! : todayCivil();
    if (triggerRef.current) setPosition(clampPopup(triggerRef.current));
    setView(base);
    setActiveDate(civilIso(base.year, base.month - 1, base.day));
    setOpen(true);
  }

  function closePicker(restoreInputFocus = false) {
    setOpen(false);
    if (restoreInputFocus) queueMicrotask(() => inputRef.current?.focus());
  }

  function changeView(amount: number, unit: "month" | "year") {
    const next = unit === "month"
      ? shiftMonth({ ...view, day: partsFromIso(activeDate)?.day ?? view.day }, amount)
      : { ...view, year: Math.min(9999, Math.max(1, view.year + amount)) };
    const day = Math.min(partsFromIso(activeDate)?.day ?? view.day, daysInMonth(next.year, next.month - 1));
    setView({ ...next, day });
    setActiveDate(civilIso(next.year, next.month - 1, day));
  }

  function moveActiveDate(nextIso: string) {
    const parts = partsFromIso(nextIso);
    if (!parts || parts.year < 1 || parts.year > 9999) return;
    setActiveDate(nextIso);
    setView(parts);
  }

  function onDayKeyDown(event: ReactKeyboardEvent<HTMLButtonElement>, iso: string) {
    const parts = partsFromIso(iso);
    if (!parts) return;
    let next: string | null = null;
    if (event.key === "ArrowLeft") next = addDays(iso, -1);
    else if (event.key === "ArrowRight") next = addDays(iso, 1);
    else if (event.key === "ArrowUp") next = addDays(iso, -7);
    else if (event.key === "ArrowDown") next = addDays(iso, 7);
    else if (event.key === "Home" || event.key === "End") {
      const weekday = dateForParts(parts).getUTCDay();
      next = addDays(iso, event.key === "Home" ? -weekday : 6 - weekday);
    } else if (event.key === "PageUp" || event.key === "PageDown") {
      const amount = event.key === "PageUp" ? -1 : 1;
      const nextParts = event.shiftKey ? { ...parts, year: parts.year + amount } : shiftMonth(parts, amount);
      const year = Math.min(9999, Math.max(1, nextParts.year));
      next = civilIso(year, nextParts.month - 1, Math.min(parts.day, daysInMonth(year, nextParts.month - 1)));
    }
    if (!next) return;
    event.preventDefault();
    moveActiveDate(next);
  }

  useLayoutEffect(() => {
    if (!open) return;
    activeDayRef.current?.focus({ preventScroll: true });
  }, [open, view.year, view.month, activeDate]);

  useEffect(() => {
    if (!open) return;
    const updatePosition = () => {
      if (triggerRef.current) setPosition(clampPopup(triggerRef.current));
    };
    const dismissOutside = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!wrapperRef.current?.contains(target) && !popupRef.current?.contains(target)) setOpen(false);
    };
    const dismissOnFocus = (event: FocusEvent) => {
      const target = event.target as Node;
      if (!wrapperRef.current?.contains(target) && !popupRef.current?.contains(target)) setOpen(false);
    };
    const dismissOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      event.stopPropagation();
      setOpen(false);
      queueMicrotask(() => inputRef.current?.focus());
    };
    document.addEventListener("pointerdown", dismissOutside);
    document.addEventListener("focusin", dismissOnFocus);
    document.addEventListener("keydown", dismissOnEscape, true);
    window.addEventListener("resize", updatePosition);
    window.addEventListener("scroll", updatePosition, true);
    return () => {
      document.removeEventListener("pointerdown", dismissOutside);
      document.removeEventListener("focusin", dismissOnFocus);
      document.removeEventListener("keydown", dismissOnEscape, true);
      window.removeEventListener("resize", updatePosition);
      window.removeEventListener("scroll", updatePosition, true);
    };
  }, [open]);

  return <div className="date-picker-field" ref={wrapperRef}>
    <input ref={inputRef} id={id} type="text" inputMode="numeric" autoComplete="off"
      placeholder="DD/MM/AAAA" maxLength={maxLength} required={required} disabled={disabled}
      aria-required={ariaRequired} aria-describedby={describedBy} value={value} onChange={(event) => onChange(event.target.value)} />
    <button ref={triggerRef} className="date-picker-trigger" type="button" disabled={disabled}
      aria-label={messages.datePickerOpen(label)} title={messages.datePickerOpen(label)}
      aria-haspopup="dialog" aria-expanded={open} aria-controls={`${id}-date-picker`}
      onFocus={openPicker} onClick={openPicker}>
      <svg aria-hidden="true" viewBox="0 0 20 20" focusable="false"><rect x="3" y="4.5" width="14" height="13" rx="1.5" />
        <path d="M6.5 2.5v4M13.5 2.5v4M3 8h14M6.5 11h.01M10 11h.01M13.5 11h.01M6.5 14h.01M10 14h.01M13.5 14h.01" /></svg>
    </button>
    {open && typeof document !== "undefined" && createPortal(
      <div ref={popupRef} id={`${id}-date-picker`} className="date-picker-popover" role="dialog"
        aria-label={messages.datePickerDialog(label)} style={{ left: position.left, top: position.top }}>
        <div className="date-picker-popover__navigation">
          <button type="button" aria-label={messages.datePickerPreviousYear} title={messages.datePickerPreviousYear}
            disabled={view.year <= 1} onClick={() => changeView(-1, "year")}>«</button>
          <button type="button" aria-label={messages.datePickerPreviousMonth} title={messages.datePickerPreviousMonth}
            disabled={view.year <= 1 && view.month <= 1} onClick={() => changeView(-1, "month")}>‹</button>
          <strong aria-live="polite">{monthTitle}</strong>
          <button type="button" aria-label={messages.datePickerNextMonth} title={messages.datePickerNextMonth}
            disabled={view.year >= 9999 && view.month >= 12} onClick={() => changeView(1, "month")}>›</button>
          <button type="button" aria-label={messages.datePickerNextYear} title={messages.datePickerNextYear}
            disabled={view.year >= 9999} onClick={() => changeView(1, "year")}>»</button>
        </div>
        <div className="date-picker-popover__grid" role="grid" aria-label={messages.datePickerMonthGrid(monthTitle)}>
          <div className="date-picker-popover__weekdays" role="row">
            {weekDays.map((day, index) => <span key={`${day}:${index}`} role="columnheader">{day}</span>)}
          </div>
          {Array.from({ length: 6 }, (_, week) => <div className="date-picker-popover__week" role="row" key={week}>
            {gridDates.slice(week * 7, week * 7 + 7).map((iso, cellIndex) => {
              if (!iso) return <div role="gridcell" aria-disabled="true" key={`date-out-of-range:${week}:${cellIndex}`} />;
              const parts = partsFromIso(iso)!;
              const isActive = activeDate === iso;
              const isSelected = selectedIso === iso;
              const inMonth = parts.year === view.year && parts.month === view.month;
              return <div role="gridcell" aria-selected={isSelected} key={iso}>
                <button ref={isActive ? activeDayRef : undefined} type="button"
                  className={`date-picker-day${isSelected ? " is-selected" : ""}${iso === todayIso ? " is-today" : ""}${!inMonth ? " is-adjacent" : ""}`}
                  tabIndex={isActive ? 0 : -1} aria-label={dateLabel(iso)} aria-current={iso === todayIso ? "date" : undefined}
                  title={formatCivilDate(iso)} onKeyDown={(event) => onDayKeyDown(event, iso)}
                  onClick={() => { onChange(formatCivilDate(iso)); closePicker(true); }}>{parts.day}</button>
              </div>;
            })}
          </div>)}
        </div>
        <small className="date-picker-popover__hint">{messages.datePickerKeyboardHint}</small>
      </div>, document.body)}
  </div>;
}
