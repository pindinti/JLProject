export interface ImportedActivity {
  sourceId: string; sourceRow: number; name: string; activityType: string | null;
  status: string | null; notes: string | null; plannedStart: string; plannedEnd: string;
  displayOrder: number;
}
export interface ImportedStage {
  code: string; color: string; displayName: string; displayOrder: number;
  activities: ImportedActivity[];
}
export interface ImportedDiscipline {
  name: string; shortCode: string; color: string; displayOrder: number;
  stages: ImportedStage[];
}
export interface ImportedMeta {
  sourceId: string; sourceRow: number; name: string; discipline: string; stage: string;
  plannedStart: string; plannedEnd: string; status: string | null; notes: string | null;
}
export interface ImportedTarget {
  name: string; sourceRow: number; targetDate: string; operationalDate: string | null;
  status: string | null; notes: string | null; displayOrder: number;
  matchedSourceId: string; matchMethod: "exact" | "date_confirmed";
}
export interface ImportSubmission {
  idempotencyKey: string; productName: string; sourceFilename: string;
  disciplines: ImportedDiscipline[]; sourceMeta: ImportedMeta[]; targets: ImportedTarget[];
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const color = /^#[0-9a-f]{6}$/i;
const sourceId = /^T\d{3}$/;
const palette = ["#336699", "#386641", "#8C4A32", "#614C94", "#2F6F73", "#806026", "#8C3D62"];

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function keys(value: Record<string, unknown>, expected: string[]): boolean {
  return Object.keys(value).length === expected.length && expected.every((key) => Object.hasOwn(value, key));
}
function label(value: unknown, max: number): value is string {
  return typeof value === "string" && value === value.trim() && value.length > 0 && value.length <= max;
}
function sourceText(value: unknown, max: number): value is string {
  return typeof value === "string" && value.trim().length > 0 && value.length <= max;
}
function nullableText(value: unknown, max: number): value is string | null {
  return value === null || sourceText(value, max);
}
function order(value: unknown, max: number): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0 && Number(value) <= max;
}
function civil(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}
function sameDate(meta: ImportedMeta, target: ImportedTarget): boolean {
  return [target.targetDate, target.operationalDate].some((value) => value === meta.plannedStart || value === meta.plannedEnd);
}
function normalized(value: string): string {
  return value.normalize("NFKC").trim().replace(/\s+/g, " ").toLocaleLowerCase("pt-BR");
}
function validActivity(value: unknown): value is ImportedActivity {
  if (!record(value) || !keys(value, ["sourceId", "sourceRow", "name", "activityType", "status", "notes",
    "plannedStart", "plannedEnd", "displayOrder"])) return false;
  return typeof value.sourceId === "string" && sourceId.test(value.sourceId) && order(value.sourceRow, 50) &&
    Number(value.sourceRow) >= 5 && label(value.name, 300) && nullableText(value.activityType, 80) &&
    nullableText(value.status, 200) && nullableText(value.notes, 4000) && civil(value.plannedStart) &&
    civil(value.plannedEnd) && value.plannedStart <= value.plannedEnd && value.displayOrder === value.sourceRow;
}
function validStage(value: unknown): value is ImportedStage {
  if (!record(value) || !keys(value, ["code", "color", "displayName", "displayOrder", "activities"])) return false;
  return label(value.code, 24) && typeof value.color === "string" && color.test(value.color) &&
    label(value.displayName, 200) && order(value.displayOrder, 50) && Array.isArray(value.activities) &&
    value.activities.length <= 41 && value.activities.every(validActivity);
}
function validDiscipline(value: unknown): value is ImportedDiscipline {
  if (!record(value) || !keys(value, ["name", "shortCode", "color", "displayOrder", "stages"])) return false;
  return label(value.name, 200) && label(value.shortCode, 24) && typeof value.color === "string" &&
    color.test(value.color) && order(value.displayOrder, 7) && Array.isArray(value.stages) &&
    value.stages.length > 0 && value.stages.length <= 21 && value.stages.every(validStage);
}
function validMeta(value: unknown): value is ImportedMeta {
  if (!record(value) || !keys(value, ["sourceId", "sourceRow", "name", "discipline", "stage",
    "plannedStart", "plannedEnd", "status", "notes"])) return false;
  return typeof value.sourceId === "string" && sourceId.test(value.sourceId) && order(value.sourceRow, 50) &&
    Number(value.sourceRow) >= 5 && sourceText(value.name, 300) && sourceText(value.discipline, 200) &&
    sourceText(value.stage, 200) && civil(value.plannedStart) && civil(value.plannedEnd) &&
    value.plannedStart <= value.plannedEnd && nullableText(value.status, 200) && nullableText(value.notes, 4000);
}
function validTarget(value: unknown): value is ImportedTarget {
  if (!record(value) || !keys(value, ["name", "sourceRow", "targetDate", "operationalDate", "status",
    "notes", "displayOrder", "matchedSourceId", "matchMethod"])) return false;
  return sourceText(value.name, 200) && order(value.sourceRow, 8) && Number(value.sourceRow) >= 4 &&
    civil(value.targetDate) && (value.operationalDate === null || civil(value.operationalDate)) &&
    nullableText(value.status, 200) && nullableText(value.notes, 4000) && order(value.displayOrder, 5) &&
    typeof value.matchedSourceId === "string" && sourceId.test(value.matchedSourceId) &&
    (value.matchMethod === "exact" || value.matchMethod === "date_confirmed");
}

export function colorForLabel(value: string): string {
  let hash = 0;
  for (const character of value.normalize("NFKC")) hash = (hash * 31 + character.codePointAt(0)!) >>> 0;
  return palette[hash % palette.length];
}

export function validateImportSubmission(value: unknown): value is ImportSubmission {
  if (!record(value) || !keys(value, ["idempotencyKey", "productName", "sourceFilename",
    "disciplines", "sourceMeta", "targets"])) return false;
  if (typeof value.idempotencyKey !== "string" || !uuid.test(value.idempotencyKey) ||
    !label(value.productName, 200) || !sourceText(value.sourceFilename, 255) ||
    !/\.xlsx$/i.test(value.sourceFilename) || !Array.isArray(value.disciplines) ||
    !Array.isArray(value.sourceMeta) || !Array.isArray(value.targets) ||
    value.disciplines.length !== 7 || value.sourceMeta.length !== 5 || value.targets.length !== 5 ||
    !value.disciplines.every(validDiscipline) || !value.sourceMeta.every(validMeta) ||
    !value.targets.every(validTarget)) return false;
  const submission = value as unknown as ImportSubmission;
  const activities = submission.disciplines.flatMap((discipline) => discipline.stages.flatMap((stage) => stage.activities));
  if (activities.length !== 41 || submission.disciplines.reduce((total, item) => total + item.stages.length, 0) !== 21) return false;
  const ids = [...activities.map((item) => item.sourceId), ...submission.sourceMeta.map((item) => item.sourceId)];
  const rows = [...activities.map((item) => item.sourceRow), ...submission.sourceMeta.map((item) => item.sourceRow)];
  if (new Set(ids).size !== 46 || new Set(rows).size !== 46 ||
    rows.some((row) => row < 5 || row > 50) ||
    ids.some((id, index) => id !== `T${String(rows[index] - 4).padStart(3, "0")}`)) return false;
  const disciplineNames = new Set<string>();
  const disciplineCodes = new Set<string>();
  const stageColors = new Map<string, string>();
  for (const [disciplineIndex, discipline] of submission.disciplines.entries()) {
    if (discipline.displayOrder !== disciplineIndex || discipline.shortCode !== `D${disciplineIndex + 1}` ||
      disciplineNames.has(normalized(discipline.name)) || disciplineCodes.has(normalized(discipline.shortCode))) return false;
    disciplineNames.add(normalized(discipline.name));
    disciplineCodes.add(normalized(discipline.shortCode));
    const codes = new Set<string>();
    for (const [stageIndex, stage] of discipline.stages.entries()) {
      const key = normalized(stage.code);
      if (stage.displayOrder !== stageIndex || stage.code !== stage.displayName || codes.has(key)) return false;
      if (stage.activities.length === 0 && !submission.sourceMeta.some((meta) =>
        meta.discipline === discipline.name && meta.stage === stage.code)) return false;
      codes.add(key);
      if (stageColors.has(key) && stageColors.get(key) !== stage.color) return false;
      stageColors.set(key, stage.color);
      if (stage.activities.some((activity, index) => index > 0 &&
        activity.sourceRow <= stage.activities[index - 1].sourceRow)) return false;
    }
  }
  const targetNames = new Set<string>();
  const targetRows = new Set<number>();
  const matchedIds = new Set<string>();
  for (const [index, target] of submission.targets.entries()) {
    const nameKey = normalized(target.name);
    if (target.displayOrder !== index || targetNames.has(nameKey) || targetRows.has(target.sourceRow) ||
      matchedIds.has(target.matchedSourceId)) return false;
    targetNames.add(nameKey); targetRows.add(target.sourceRow); matchedIds.add(target.matchedSourceId);
    const meta = submission.sourceMeta.find((item) => item.sourceId === target.matchedSourceId);
    if (!meta || !sameDate(meta, target)) return false;
    const sameName = normalized(meta.name) === nameKey;
    if (target.matchMethod === "exact" && !sameName) return false;
    if (target.matchMethod === "date_confirmed" && (sameName ||
      submission.targets.some((item) => normalized(item.name) === normalized(meta.name)) ||
      submission.targets.filter((item) => sameDate(meta, item)).length !== 1)) return false;
  }
  return matchedIds.size === 5 && submission.sourceMeta.every((item) => matchedIds.has(item.sourceId));
}

export function importSourceContent(submission: ImportSubmission): unknown {
  return { disciplines: submission.disciplines.map((discipline) => ({
    name: discipline.name, displayOrder: discipline.displayOrder,
    stages: discipline.stages.map((stage) => ({
      displayName: stage.displayName, displayOrder: stage.displayOrder, activities: stage.activities
    }))
  })), sourceMeta: submission.sourceMeta,
    targets: submission.targets.map((target) => ({ name: target.name, sourceRow: target.sourceRow,
      targetDate: target.targetDate, operationalDate: target.operationalDate,
      status: target.status, notes: target.notes, displayOrder: target.displayOrder })) };
}
