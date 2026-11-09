import { describe, expect, it } from "vitest";
import { getFirstName, getGreetingPeriod } from "../src/design/header";

describe("global header helpers", () => {
  it("uses the display name and falls back to the email name", () => {
    expect(getFirstName("  Camila Tawany  ", "camila@example.com")).toBe("Camila");
    expect(getFirstName(null, "gislaine.silva@example.com")).toBe("gislaine.silva");
    expect(getFirstName(" ", null)).toBe("pessoa");
  });

  it("selects the greeting from São Paulo local time", () => {
    expect(getGreetingPeriod(new Date("2026-11-09T10:59:00Z"))).toBe("morning");
    expect(getGreetingPeriod(new Date("2026-11-09T15:00:00Z"))).toBe("afternoon");
    expect(getGreetingPeriod(new Date("2026-11-09T22:00:00Z"))).toBe("evening");
  });
});
