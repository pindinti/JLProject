import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ColorField } from "../src/ColorField";
import { ganttPresetColors, layoutMilestoneLabels } from "../src/design/gantt-colors";

describe("Gantt color controls", () => {
  it("offers the documented 16 color presets and retains a saved custom value", () => {
    const onChange = vi.fn();
    render(<ColorField id="test-color" label="Cor" value="#AA4557" onChange={onChange} />);

    expect(ganttPresetColors).toEqual([
      "#52694D", "#8D9A89", "#355F52", "#3C8792", "#355C7D", "#4A79A8", "#667D91", "#5F68A5",
      "#8560A4", "#A16E8D", "#805069", "#8C3B35", "#B9654E", "#B98738", "#D2A357", "#6F7772"
    ]);
    expect(screen.getAllByRole("button")).toHaveLength(16);
    expect(screen.getByLabelText("Código hexadecimal")).toHaveValue("#AA4557");
    expect(screen.getByLabelText("Selecionar cor personalizada para Cor")).toHaveValue("#aa4557");
    expect(onChange).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Selecionar cor #52694D" }));
    expect(onChange).toHaveBeenCalledWith("#52694D");
  });

  it("accepts arbitrary valid hexadecimal colors without restricting the preset palette", () => {
    const onChange = vi.fn();
    render(<ColorField id="test-color" label="Cor do marco" value="#AA4557" onChange={onChange} />);
    const hex = screen.getByLabelText("Código hexadecimal");
    fireEvent.change(hex, { target: { value: "#12aBcD" } });
    expect(onChange).toHaveBeenCalledWith("#12aBcD");
    expect(hex).toBeValid();
    fireEvent.change(hex, { target: { value: "#1234" } });
    expect(hex).toBeInvalid();
    expect(onChange).toHaveBeenCalledTimes(1);
  });
});

describe("milestone label layout", () => {
  it("keeps complete names and places close milestones on separate lanes", () => {
    const labels = layoutMilestoneLabels([
      { id: "one", name: "Synthetic imported target name one", targetDate: "2026-11-10" },
      { id: "two", name: "Synthetic target name two", targetDate: "2026-11-11" },
      { id: "three", name: "Distant target", targetDate: "2026-12-10" }
    ], (date) => date === "2026-11-10" ? 100 : date === "2026-11-11" ? 120 : 500, 800);

    expect(labels.map(({ name }) => name)).toEqual([
      "Synthetic imported target name one", "Synthetic target name two", "Distant target"
    ]);
    expect(labels[0]?.lane).not.toBe(labels[1]?.lane);
    expect(labels[2]?.lane).toBe(labels[0]?.lane);
    expect(labels[0]!.left + labels[0]!.width).toBeLessThanOrEqual(labels[2]!.left);
  });

  it("keeps labels within the timeline when a name exceeds available space", () => {
    const [label] = layoutMilestoneLabels([
      { id: "long", name: "A very long target name that cannot fit", targetDate: "2026-11-10" }
    ], () => 20, 120);
    expect(label).toMatchObject({ left: 0, width: 120, lane: 0 });
  });
});
