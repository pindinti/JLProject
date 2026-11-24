import { civilFromDay } from "../domain/schedule-workspace";
import type { PrintDateSegment } from "./print-pagination";

export type PrintFit = "automatic" | "width" | "single";
export type PrintDetail = "current" | "products" | "disciplines" | "stages" | "activities";

export interface PrintOptions {
  detail: PrintDetail;
  range?: PrintDateSegment;
  fit: PrintFit;
  showMilestones: boolean;
  showToday: boolean;
}

export function visiblePrintRange(startDay: number, endDay: number, dayWidth: number,
  scrollLeft: number, plotWidth: number): PrintDateSegment | undefined {
  if (![startDay, endDay, dayWidth, scrollLeft, plotWidth].every(Number.isFinite) ||
    dayWidth <= 0 || plotWidth <= 0 || startDay > endDay) return;
  const left = Math.max(0, scrollLeft);
  const last = endDay - startDay;
  const firstVisible = Math.min(last, Math.floor(left / dayWidth));
  const lastVisible = Math.min(last, Math.ceil((left + plotWidth) / dayWidth) - 1);
  return { start: civilFromDay(startDay + firstVisible), end: civilFromDay(startDay + lastVisible) };
}

export function singleSheetScale(widthMm: number, heightMm: number): number {
  return Math.min(1, 400 / widthMm, 276 / heightMm);
}

export const printReadabilityThreshold = 7;
