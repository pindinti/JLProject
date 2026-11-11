import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { DatePickerField } from "../src/DatePickerField";

function ControlledDateField({ initialValue = "09/11/2026", onChange = vi.fn() }: {
  initialValue?: string; onChange?: (value: string) => void;
}) {
  const [value, setValue] = useState(initialValue);
  return <div><label htmlFor="synthetic-date">Data planejada</label>
    <DatePickerField id="synthetic-date" label="Data planejada" value={value}
      onChange={(next) => { onChange(next); setValue(next); }} />
  </div>;
}

describe("DatePickerField", () => {
  it("opens on calendar-control focus, navigates by year, and emits a pt-BR civil date on selection", async () => {
    const onChange = vi.fn();
    render(<ControlledDateField onChange={onChange} />);
    const trigger = screen.getByRole("button", { name: "Abrir calendário para Data planejada" });
    fireEvent.focus(trigger);
    const dialog = await screen.findByRole("dialog", { name: "Escolher data para Data planejada" });
    expect(within(dialog).getByText("novembro de 2026")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Próximo mês" }));
    expect(within(dialog).getByText("dezembro de 2026")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "Mês anterior" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Próximo ano" }));
    expect(within(dialog).getByText("novembro de 2027")).toBeInTheDocument();
    fireEvent.click(within(dialog).getByRole("button", { name: "terça-feira, 9 de novembro de 2027" }));
    expect(onChange).toHaveBeenCalledWith("09/11/2027");
    expect(screen.getByLabelText("Data planejada")).toHaveValue("09/11/2027");
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Escolher data para Data planejada" }))
      .not.toBeInTheDocument());
    expect(trigger).toHaveAttribute("aria-expanded", "false");
  });

  it("supports arrow-key date navigation, selection, and Escape dismissal with focus return", async () => {
    render(<ControlledDateField />);
    const trigger = screen.getByRole("button", { name: "Abrir calendário para Data planejada" });
    fireEvent.click(trigger);
    const dialog = await screen.findByRole("dialog", { name: "Escolher data para Data planejada" });
    const ninth = within(dialog).getByRole("button", { name: "segunda-feira, 9 de novembro de 2026" });
    expect(document.activeElement).toBe(ninth);
    fireEvent.keyDown(ninth, { key: "ArrowRight" });
    const tenth = within(dialog).getByRole("button", { name: /10 de novembro de 2026/ });
    expect(document.activeElement).toBe(tenth);
    fireEvent.keyDown(tenth, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Escolher data para Data planejada" }))
      .not.toBeInTheDocument());
    expect(document.activeElement).toBe(screen.getByLabelText("Data planejada"));
    expect(trigger).toHaveAttribute("aria-expanded", "false");
  });

  it("keeps manual text entry, including invalid values, under the existing form validation", () => {
    const onChange = vi.fn();
    render(<ControlledDateField initialValue="" onChange={onChange} />);
    const input = screen.getByLabelText("Data planejada");
    fireEvent.change(input, { target: { value: "31/02/2026" } });
    expect(input).toHaveValue("31/02/2026");
    expect(onChange).toHaveBeenCalledWith("31/02/2026");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });
});
