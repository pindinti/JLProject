import { flushSync } from "react-dom";
import { printReadabilityThreshold, singleSheetScale } from "./schedule-print-options";

export function printSchedule(setPrinting: (printing: boolean) => void, acceptWarning = false): boolean {
  document.body.classList.add("printing-schedule");
  let restoreOutput: (() => void) | undefined;
  try {
    flushSync(() => setPrinting(true));
    const output = document.querySelector<HTMLElement>(".print-document");
    const single = output?.querySelector<HTMLElement>(".print-single-content");
    const bounds = single?.getBoundingClientRect();
    const scale = bounds && bounds.width > 0 && bounds.height > 0
      ? singleSheetScale(bounds.width * 25.4 / 96, bounds.height * 25.4 / 96) : 1;
    if (!acceptWarning && (scale * 8 < printReadabilityThreshold || output?.dataset.printDensityWarning === "true"))
      return false;
    if (single) {
      single.style.position = "absolute";
      single.style.inset = "10mm auto auto 10mm";
      single.style.width = "400mm";
      single.style.transform = `scale(${scale})`;
    }
    if (output?.parentElement) {
      const parent = output.parentElement;
      const next = output.nextSibling;
      restoreOutput = () => parent.insertBefore(output, next);
      document.body.append(output);
    }
    window.print();
    return true;
  } finally {
    restoreOutput?.();
    document.body.classList.remove("printing-schedule");
    flushSync(() => setPrinting(false));
  }
}
