import { ganttPresetColors } from "./design/gantt-colors";

export const recentColorLimit = 8;

export function normalizeHexColor(value: unknown): string | null {
  return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value) ? value.toUpperCase() : null;
}

function storageKey(userId: string | null | undefined): string | null {
  return typeof userId === "string" && userId.trim().length > 0
    ? `jlproject:recent-custom-colors:v1:${encodeURIComponent(userId)}` : null;
}

function browserStorage(): Storage | null {
  try { return typeof window === "undefined" ? null : window.localStorage; }
  catch { return null; }
}

function isCustomColor(color: string): boolean {
  return !(ganttPresetColors as readonly string[]).includes(color);
}

function normalizeColorList(values: unknown): string[] {
  if (!Array.isArray(values)) return [];
  const colors: string[] = [];
  for (const value of values) {
    const color = normalizeHexColor(value);
    if (!color || !isCustomColor(color) || colors.includes(color)) continue;
    colors.push(color);
    if (colors.length === recentColorLimit) break;
  }
  return colors;
}

export function readRecentCustomColors(userId: string | null | undefined, storage = browserStorage()): string[] {
  const key = storageKey(userId);
  if (!key || !storage) return [];
  try {
    const stored = storage.getItem(key);
    return stored ? normalizeColorList(JSON.parse(stored) as unknown) : [];
  } catch { return []; }
}

export function rememberRecentCustomColor(
  userId: string | null | undefined,
  value: unknown,
  storage = browserStorage()
): string[] {
  const key = storageKey(userId);
  const color = normalizeHexColor(value);
  const current = readRecentCustomColors(userId, storage);
  if (!key || !color || !isCustomColor(color)) return current;

  const next = [color, ...current.filter((recent) => recent !== color)].slice(0, recentColorLimit);
  try { storage?.setItem(key, JSON.stringify(next)); } catch { /* Storage can be unavailable or full. */ }
  return next;
}
