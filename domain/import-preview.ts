export type ImportIssueCode = "structure" | "header" | "row_limit" | "required" | "duplicate_id" |
  "date" | "range" | "target_match" | "untrusted_text" | "count";
export interface ImportIssue { severity: "error" | "warning"; code: ImportIssueCode; sheet: string; row?: number }
export interface PreviewActivity {
  sourceId: string; sourceRow: number; name: string; type: string | null;
  status: string | null; notes: string | null; plannedStart: string; plannedEnd: string;
}
export interface PreviewStage { name: string; activities: PreviewActivity[] }
export interface PreviewDiscipline { name: string; stages: PreviewStage[] }
export interface PreviewTarget {
  name: string; sourceRow: number; targetDate: string; operationalDate: string | null;
  status: string | null; notes: string | null; matchedSourceId: string | null;
}
export interface PreviewMeta {
  sourceId: string; sourceRow: number; name: string; discipline: string; stage: string;
  plannedStart: string; plannedEnd: string; status: string | null; notes: string | null;
  matchKind: "exact" | "date_suggestion" | "unresolved";
  suggestedTargetRow: number | null;
}
export interface ImportPreview {
  productSuggestion: string; disciplines: PreviewDiscipline[]; targets: PreviewTarget[]; sourceMeta: PreviewMeta[];
  issues: ImportIssue[]; summary: { sourceRecords: number; activities: number; targets: number;
    disciplines: number; dependencies: 0; firstDate: string | null; lastDate: string | null };
}

type Cell = string | number | boolean | Date | null | undefined;
export interface ImportSheet { sheet: string; data: Cell[][] }
const sourceSheet = "Cronograma Produto";
const targetSheet = "Metas e Premissas";
const sourceHeaders = new Map<number, string>([
  [0, "ID"], [1, "Disciplina"], [2, "Etapa"], [3, "Atividade de Produto"],
  [4, "Início"], [5, "Fim"], [9, "Status"], [10, "Tipo"], [11, "Observações"]
]);
const dayMs = 86400000;

function text(value: Cell): string | null {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const result = String(value).trim();
  return result || null;
}

function sourceText(value: Cell): string | null {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const result = String(value);
  return result.trim() ? result : null;
}

function civilDate(value: Cell, date1904: boolean): string | null {
  if (value instanceof Date) {
    if (!Number.isFinite(value.getTime())) return null;
    return value.toISOString().slice(0, 10);
  }
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || value < (date1904 ? 0 : 1) || (!date1904 && value === 60)) return null;
    const offset = date1904 ? 0 : value < 60 ? -1 : -2;
    const base = date1904 ? Date.UTC(1904, 0, 1) : Date.UTC(1900, 0, 1);
    const result = new Date(base + (value + offset) * dayMs);
    return Number.isFinite(result.getTime()) ? result.toISOString().slice(0, 10) : null;
  }
  if (typeof value === "string") {
    const match = value.trim().match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (match) {
      const result = new Date(`${match[1]}-${match[2]}-${match[3]}T00:00:00.000Z`);
      return Number.isFinite(result.getTime()) && result.toISOString().slice(0, 10) === match[0] ? match[0] : null;
    }
  }
  return null;
}

function looksExecutable(value: string): boolean {
  const first = [...value].find((character) => character.trim() !== "" && character.charCodeAt(0) > 31);
  return first === "=" || first === "+" || first === "-" || first === "@";
}
function matchKey(value: string): string { return value.normalize("NFKC").trim().replace(/\s+/g, " ").toLocaleLowerCase("pt-BR"); }
function rowUsed(row: Cell[], columns: number[]): boolean {
  return columns.some((index) => row[index] !== null && row[index] !== undefined && row[index] !== "");
}

export function parseImportSheets(sheets: ImportSheet[], filename: string, date1904 = false): ImportPreview {
  const issues: ImportIssue[] = [];
  const disciplines: PreviewDiscipline[] = [];
  const targets: PreviewTarget[] = [];
  const sourceMeta: PreviewMeta[] = [];
  const source = sheets.find((item) => item.sheet === sourceSheet)?.data as Cell[][] | undefined;
  const official = sheets.find((item) => item.sheet === targetSheet)?.data as Cell[][] | undefined;
  const summary = { sourceRecords: 0, activities: 0, targets: 0, disciplines: 0, dependencies: 0 as const,
    firstDate: null as string | null, lastDate: null as string | null };
  const preview: ImportPreview = { productSuggestion: filename.replace(/\.xlsx$/i, "").replace(/[_-]+/g, " ").trim(),
    disciplines, targets, sourceMeta, issues, summary };
  if (!source || !official) {
    issues.push({ severity: "error", code: "structure", sheet: !source ? sourceSheet : targetSheet });
    return preview;
  }
  for (const [column, expected] of sourceHeaders) {
    if (text(source[3]?.[column]) !== expected) issues.push({ severity: "error", code: "header", sheet: sourceSheet, row: 4 });
  }
  if (!text(official[2]?.[0]) || !text(official[2]?.[1]))
    issues.push({ severity: "error", code: "header", sheet: targetSheet, row: 3 });
  if (issues.length) return preview;
  const seenIds = new Set<string>();
  for (let index = 4; index < source.length; index++) {
    const row = (source[index] ?? []) as Cell[];
    if (!rowUsed(row, [0, 1, 2, 3, 4, 5, 9, 10, 11])) continue;
    if (index > 49) { issues.push({ severity: "error", code: "row_limit", sheet: sourceSheet, row: index + 1 }); break; }
    summary.sourceRecords++;
    const [idValue, disciplineValue, stageValue, nameValue, startValue, endValue] = row;
    const id = text(idValue); const disciplineName = sourceText(disciplineValue);
    const stageName = sourceText(stageValue); const name = sourceText(nameValue);
    const start = civilDate(startValue, date1904); const end = civilDate(endValue, date1904);
    if (!id || !disciplineName || !stageName || !name) {
      issues.push({ severity: "error", code: "required", sheet: sourceSheet, row: index + 1 }); continue;
    }
    if (seenIds.has(id)) { issues.push({ severity: "error", code: "duplicate_id", sheet: sourceSheet, row: index + 1 }); continue; }
    seenIds.add(id);
    if (!start || !end) { issues.push({ severity: "error", code: "date", sheet: sourceSheet, row: index + 1 }); continue; }
    if (start > end) { issues.push({ severity: "error", code: "range", sheet: sourceSheet, row: index + 1 }); continue; }
    const type = sourceText(row[10]);
    if (type && matchKey(type) === "meta") sourceMeta.push({ sourceId: id, sourceRow: index + 1,
      name, discipline: disciplineName, stage: stageName, plannedStart: start, plannedEnd: end,
      status: sourceText(row[9]), notes: sourceText(row[11]),
      matchKind: "unresolved", suggestedTargetRow: null });
    else {
      let discipline = disciplines.find((item) => item.name === disciplineName);
      if (!discipline) { discipline = { name: disciplineName, stages: [] }; disciplines.push(discipline); }
      let stage = discipline.stages.find((item) => item.name === stageName);
      if (!stage) { stage = { name: stageName, activities: [] }; discipline.stages.push(stage); }
      stage.activities.push({ sourceId: id, sourceRow: index + 1, name, type,
        status: sourceText(row[9]), notes: sourceText(row[11]), plannedStart: start, plannedEnd: end });
      summary.activities++;
    }
    for (const date of [start, end]) {
      if (!summary.firstDate || date < summary.firstDate) summary.firstDate = date;
      if (!summary.lastDate || date > summary.lastDate) summary.lastDate = date;
    }
    if ([id, disciplineName, stageName, name, sourceText(row[9]), type, sourceText(row[11])].some((value) => value && looksExecutable(value))) {
      issues.push({ severity: "warning", code: "untrusted_text", sheet: sourceSheet, row: index + 1 });
    }
  }
  const targetKeys = new Set<string>();
  for (let index = 3; index < official.length; index++) {
    const row = (official[index] ?? []) as Cell[];
    if (!rowUsed(row, [0, 1, 2, 3, 4])) continue;
    if (index > 7) break;
    const name = sourceText(row[0]); const targetDate = civilDate(row[1], date1904);
    if (!name || !targetDate) { issues.push({ severity: "error", code: "required", sheet: targetSheet, row: index + 1 }); continue; }
    const key = matchKey(name);
    if (targetKeys.has(key)) { issues.push({ severity: "error", code: "target_match", sheet: targetSheet, row: index + 1 }); continue; }
    targetKeys.add(key);
    const operationalDate = row[2] === null || row[2] === undefined || row[2] === "" ? null : civilDate(row[2], date1904);
    if (row[2] !== null && row[2] !== undefined && row[2] !== "" && !operationalDate)
      issues.push({ severity: "error", code: "date", sheet: targetSheet, row: index + 1 });
    targets.push({ name, sourceRow: index + 1, targetDate, operationalDate,
      status: sourceText(row[3]), notes: sourceText(row[4]), matchedSourceId: null });
    if (looksExecutable(name) || [sourceText(row[3]), sourceText(row[4])].some((value) => value && looksExecutable(value)))
      issues.push({ severity: "warning", code: "untrusted_text", sheet: targetSheet, row: index + 1 });
  }
  const dateMatches = (meta: PreviewMeta, target: PreviewTarget) =>
    [target.targetDate, target.operationalDate].some((date) => date === meta.plannedStart || date === meta.plannedEnd);
  for (const meta of sourceMeta) {
    const matches = targets.filter((target) => matchKey(target.name) === matchKey(meta.name) && dateMatches(meta, target));
    if (matches.length === 1 && !matches[0].matchedSourceId) {
      matches[0].matchedSourceId = meta.sourceId;
      meta.matchKind = "exact";
      meta.suggestedTargetRow = matches[0].sourceRow;
    }
  }
  for (const meta of sourceMeta.filter((item) => item.matchKind === "unresolved")) {
    const conflictingName = targets.some((target) => matchKey(target.name) === matchKey(meta.name));
    const candidates = conflictingName ? [] : targets.filter((target) => !target.matchedSourceId && dateMatches(meta, target));
    const candidate = candidates.length === 1 ? candidates[0] : null;
    const competing = candidate && sourceMeta.some((other) => other !== meta && other.matchKind !== "exact" &&
      !targets.some((target) => matchKey(target.name) === matchKey(other.name)) && dateMatches(other, candidate));
    if (candidate && !competing) {
      meta.matchKind = "date_suggestion";
      meta.suggestedTargetRow = candidate.sourceRow;
    }
    issues.push({ severity: "warning", code: "target_match", sheet: sourceSheet, row: meta.sourceRow });
  }
  summary.targets = targets.length;
  summary.disciplines = disciplines.length;
  if (summary.sourceRecords !== 46 || summary.activities !== 41 || targets.length !== 5 || sourceMeta.length !== 5 || disciplines.length !== 7)
    issues.push({ severity: "warning", code: "count", sheet: sourceSheet });
  return preview;
}
