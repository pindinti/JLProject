import { beforeEach, describe, expect, it } from "vitest";
import { readRecentCustomColors, recentColorLimit, rememberRecentCustomColor } from "../src/recent-color-history";

const firstUser = "user-a";
const secondUser = "user-b";
const keyFor = (userId: string) => `jlproject:recent-custom-colors:v1:${encodeURIComponent(userId)}`;

beforeEach(() => localStorage.clear());

describe("recent custom color history", () => {
  it("normalizes HEX values, deduplicates them, and moves reused colors first", () => {
    expect(rememberRecentCustomColor(firstUser, "#aabbcc")).toEqual(["#AABBCC"]);
    expect(rememberRecentCustomColor(firstUser, "#112233")).toEqual(["#112233", "#AABBCC"]);
    expect(rememberRecentCustomColor(firstUser, "#AABBCC")).toEqual(["#AABBCC", "#112233"]);
    expect(rememberRecentCustomColor(firstUser, "#12abc")).toEqual(["#AABBCC", "#112233"]);
  });

  it("keeps only the eight newest distinct custom colors and excludes curated presets", () => {
    const colors = Array.from({ length: recentColorLimit + 1 }, (_, index) =>
      `#${(index + 1).toString(16).padStart(6, "0")}`);
    let history: string[] = [];
    for (const color of colors) history = rememberRecentCustomColor(firstUser, color);

    expect(history).toHaveLength(8);
    expect(history[0]).toBe("#000009");
    expect(history).not.toContain("#52694D");
    expect(rememberRecentCustomColor(firstUser, "#52694D")).toEqual(history);
  });

  it("persists across reloads and isolates each authenticated user", () => {
    rememberRecentCustomColor(firstUser, "#123456");
    rememberRecentCustomColor(secondUser, "#ABCDEF");

    expect(readRecentCustomColors(firstUser)).toEqual(["#123456"]);
    expect(readRecentCustomColors(secondUser)).toEqual(["#ABCDEF"]);
    expect(localStorage.getItem(keyFor(firstUser))).toBe('["#123456"]');
    expect(localStorage.getItem(keyFor(secondUser))).toBe('["#ABCDEF"]');
  });

  it("ignores malformed storage and tolerates storage failures", () => {
    localStorage.setItem(keyFor(firstUser), "not-json");
    expect(readRecentCustomColors(firstUser)).toEqual([]);
    localStorage.setItem(keyFor(firstUser), JSON.stringify(["#abcdef", "#ABCDEF", "invalid", "#52694D"]));
    expect(readRecentCustomColors(firstUser)).toEqual(["#ABCDEF"]);

    const unavailable = { getItem: () => { throw new Error("unavailable"); },
      setItem: () => { throw new Error("unavailable"); } } as unknown as Storage;
    expect(readRecentCustomColors(firstUser, unavailable)).toEqual([]);
    expect(rememberRecentCustomColor(firstUser, "#123456", unavailable)).toEqual(["#123456"]);
  });
});
