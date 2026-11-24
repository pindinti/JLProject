import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { SchedulePrintDialog } from "../src/SchedulePrintDialog";
import { visiblePrintRange, singleSheetScale } from "../src/schedule-print-options";
import { dayNumber } from "../domain/schedule-workspace";

const details = [{ value: "current", label: "Visibilidade atual" }, { value: "stages", label: "Disciplinas e etapas" }] as const;
const visibleRange = { start: "2026-02-10", end: "2026-02-17" };

describe("schedule print configuration", () => {
  it("opens with read-only default settings and only offers the accessible version", () => {
    const print = vi.fn().mockReturnValue(true);
    const close = vi.fn();
    render(<SchedulePrintDialog individual details={details} currentDetail="current" visibleRange={visibleRange}
      onPrint={print} onClose={close} />);
    expect(screen.getByText("A3 paisagem · Margens de 10 mm")).toBeInTheDocument();
    expect(screen.getByRole("group", { name: /elementos adicionais/i })).toBeInTheDocument();
    expect(screen.getByText("Cancelar").closest("button")).toHaveClass("jl-button--secondary");
    expect(screen.getByRole("button", { name: /abrir impressão/i })).toHaveClass("jl-button--primary");
    expect(screen.getByLabelText(/Versão do cronograma/)).toBeDisabled();
    expect(screen.getByLabelText(/Linhas de dependência/)).toBeDisabled();
    expect(print).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Abrir impressão" }));
    expect(print).toHaveBeenCalledWith({
      detail: "current", range: undefined, fit: "automatic", showMilestones: true, showToday: true,
    }, false);
    expect(close).toHaveBeenCalledOnce();
  });

  it("prints the captured visible range with overrides without changing visibility choices outside the dialog", () => {
    const print = vi.fn().mockReturnValue(true);
    render(<SchedulePrintDialog details={details} currentDetail="current" visibleRange={visibleRange}
      onPrint={print} onClose={vi.fn()} />);
    fireEvent.change(screen.getByLabelText("Detalhamento"), { target: { value: "stages" } });
    fireEvent.change(screen.getByLabelText("Período"), { target: { value: "visible" } });
    fireEvent.change(screen.getByLabelText("Escala"), { target: { value: "width" } });
    fireEvent.click(screen.getByLabelText("Marcos e metas"));
    fireEvent.click(screen.getByLabelText("Indicador de hoje"));
    fireEvent.click(screen.getByRole("button", { name: "Abrir impressão" }));
    expect(print).toHaveBeenCalledWith({
      detail: "stages", range: visibleRange, fit: "width", showMilestones: false, showToday: false,
    }, false);
  });

  it("rejects invalid and inverted custom dates and lets the user proceed after a fit warning", () => {
    const print = vi.fn().mockReturnValueOnce(false).mockReturnValueOnce(true);
    const close = vi.fn();
    render(<SchedulePrintDialog details={details} currentDetail="current" visibleRange={visibleRange}
      onPrint={print} onClose={close} />);
    fireEvent.change(screen.getByLabelText("Período"), { target: { value: "custom" } });
    fireEvent.change(screen.getByLabelText("Início"), { target: { value: "29/02/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Abrir impressão" }));
    expect(screen.getByRole("alert")).toHaveTextContent("Informe datas válidas");
    fireEvent.change(screen.getByLabelText("Início"), { target: { value: "20/02/2026" } });
    fireEvent.click(screen.getByRole("button", { name: "Abrir impressão" }));
    expect(print).not.toHaveBeenCalled();
    fireEvent.change(screen.getByLabelText("Fim"), { target: { value: "20/02/2026" } });
    fireEvent.change(screen.getByLabelText("Escala"), { target: { value: "single" } });
    fireEvent.click(screen.getByRole("button", { name: "Abrir impressão" }));
    expect(screen.getByRole("alert")).toHaveTextContent("difíceis de ler");
    expect(screen.getByRole("alert")).toHaveFocus();
    expect(close).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Imprimir assim mesmo" }));
    expect(print.mock.calls[0][0]).toEqual(print.mock.calls[1][0]);
    expect(print).toHaveBeenLastCalledWith(expect.objectContaining({
      range: { start: "2026-02-20", end: "2026-02-20" }, fit: "single",
    }), true);
    expect(close).toHaveBeenCalledOnce();
  });

  it("cancels without printing and can dismiss on Escape", () => {
    const print = vi.fn();
    const close = vi.fn();
    render(<SchedulePrintDialog details={details} currentDetail="current" onPrint={print} onClose={close} />);
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
    expect(close).toHaveBeenCalledOnce();
    expect(print).not.toHaveBeenCalled();
  });
});

describe("print dimensions", () => {
  it("clips viewport coordinates and includes partially visible civil days", () => {
    const start = dayNumber("2026-01-01");
    expect(visiblePrintRange(start, start + 9, 10, 5, 15)).toEqual({ start: "2026-01-01", end: "2026-01-02" });
    expect(visiblePrintRange(start, start + 9, 10, 85, 40)).toEqual({ start: "2026-01-09", end: "2026-01-10" });
    expect(visiblePrintRange(start, start + 9, 10, 0, 0)).toBeUndefined();
  });

  it("uses the smaller fitting dimension and retains the default size when possible", () => {
    expect(singleSheetScale(400, 200)).toBe(1);
    expect(singleSheetScale(400, 552)).toBe(0.5);
    expect(singleSheetScale(800, 200)).toBe(0.5);
  });
});
