import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

const styles = readFileSync("src/styles.css", "utf8");
const tokens = readFileSync("src/design/jlproject-tokens.css", "utf8");

describe("compact schedule density styles", () => {
  it("sets synchronized table and Gantt rows to 30px and keeps row controls compact", () => {
    const compactTokens = tokens.match(/\[data-density="compact"\]\s*\{([^}]+)\}/)?.[1] ?? "";
    expect(compactTokens).toContain("--jl-table-row-height: 30px");
    expect(compactTokens).toContain("--jl-gantt-row-height: 30px");
    expect(styles).toContain(".workspace-table-row { height: var(--jl-table-row-height);");
    expect(styles).toContain(".workspace-chart-row { height: var(--jl-gantt-row-height);");
    expect(styles).toContain("grid-template-columns: minmax(0, 1fr) 6.7rem 6.7rem;");
    expect(styles).toContain(".workspace-inline-actions button.workspace-icon-action {");
    expect(styles).toContain("min-height: 24px;");
  });

  it("overrides the global dark button hover on activity names while retaining full-row selection", () => {
    expect(styles).toMatch(/\.schedule-workspace \.workspace-row-name:not\(:disabled\):hover\s*\{\s*background:\s*transparent;\s*\}/);
    expect(styles).toMatch(/\.workspace-table-row\.selected,[\s\S]*?\.workspace-chart-row\.selected,[\s\S]*?\.workspace-chart-row:hover\s*\{ background: var\(--jl-primary-soft\); \}/);
  });
});
