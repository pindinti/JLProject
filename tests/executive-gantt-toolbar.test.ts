// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync("src/styles.css", "utf8");

describe("compact Executive Gantt toolbar layout", () => {
  it("keeps desktop controls in one line and enables wrapping at narrow widths", () => {
    expect(css).toMatch(/\.executive-gantt__controls\s*\{[^}]*flex-wrap:\s*nowrap;/s);
    expect(css).toMatch(/@media\s*\(max-width:\s*54rem\)\s*\{\s*\.executive-gantt__controls\s*\{\s*flex-wrap:\s*wrap;/s);
    expect(css).toMatch(/\.executive-gantt__toolbar-actions\s*\{[^}]*margin-left:\s*auto;/s);
    expect(css).toMatch(/\.executive-gantt__toggle input\s*\{[^}]*width:\s*14px;[^}]*height:\s*14px;/s);
  });
});
