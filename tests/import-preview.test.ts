import { describe, expect, it } from "vitest";
import type { ImportSheet } from "../domain/import-preview";
import { zipSync, strToU8 } from "fflate";
import { parseImportSheets } from "../domain/import-preview";
import { ImportFileError, parseWorkbookFile, validateXlsxArchive } from "../src/import-xlsx";

const headers = ["ID", "Disciplina", "Etapa", "Atividade de Produto", "Início", "Fim",
  "Duração (dias úteis)", "Predecessora", "Data-meta", "Status", "Tipo", "Observações"];

function sheets(): ImportSheet[] {
  const source: ImportSheet["data"] = [[], [], [], [...headers]];
  const targets: ImportSheet["data"] = [[], [], ["Meta", "Data", "Data operacional", "Status", "Observações"]];
  for (let index = 1; index <= 46; index++) {
    const meta = index > 41;
    const number = meta ? index - 41 : index;
    source.push([`T${String(index).padStart(3, "0")}`, `Disciplina ${((index - 1) % 7) + 1}`,
      "EC", meta ? `Meta ${number}` : `Atividade R01 ${number}`,
      new Date(Date.UTC(2026, 9, 21)), new Date(Date.UTC(2026, 10, 2)),
      "=SUM(E5:F5)", "=T001", null, "Em andamento", meta ? "Meta" : "Análise", "Observação sintética"]);
    if (meta) targets.push([`Meta ${number}`, new Date(Date.UTC(2026, 9, 21)), null, "Prevista", null]);
  }
  return [{ sheet: "Cronograma Produto", data: source }, { sheet: "Metas e Premissas", data: targets }];
}

describe("import preview parser", () => {
  it("preserves 46 source records, 41 activities, five targets, seven disciplines, and no dependencies", () => {
    const result = parseImportSheets(sheets(), "Synthetic.xlsx");
    expect(result.summary).toMatchObject({ sourceRecords: 46, activities: 41, targets: 5,
      disciplines: 7, dependencies: 0, firstDate: "2026-10-21", lastDate: "2026-11-02" });
    expect(result.disciplines[0].stages[0].activities[0]).toMatchObject({
      sourceId: "T001", sourceRow: 5, name: "Atividade R01 1", plannedStart: "2026-10-21"
    });
    expect(result.targets.every((target) => target.matchedSourceId)).toBe(true);
    expect(JSON.stringify(result)).not.toContain("=T001");
    expect(JSON.stringify(result)).not.toContain("=SUM");
    expect(result.issues).toEqual([]);
  });

  it("reports duplicate IDs, missing dates, invalid ranges, and unsupported headers", () => {
    const duplicate = sheets();
    duplicate[0].data[5][0] = "T001";
    duplicate[0].data[6][4] = null;
    duplicate[0].data[7][4] = new Date(Date.UTC(2026, 11, 1));
    const result = parseImportSheets(duplicate, "Synthetic.xlsx");
    expect(result.issues.map((issue) => issue.code)).toEqual(expect.arrayContaining(["duplicate_id", "date", "range"]));
    const malformed = sheets();
    malformed[0].data[3][4] = "Start";
    expect(parseImportSheets(malformed, "Synthetic.xlsx").issues[0].code).toBe("header");
    expect(parseImportSheets([], "Synthetic.xlsx").issues[0].code).toBe("structure");
  });

  it("does not guess ambiguous target matches or merge distinct stage labels", () => {
    const fixture = sheets();
    fixture[1].data[4][1] = new Date(Date.UTC(2027, 0, 1));
    fixture[0].data[5][1] = "Disciplina 1";
    fixture[0].data[5][2] = "EC ";
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    expect(result.issues.some((issue) => issue.code === "target_match")).toBe(true);
    expect(result.targets[1].matchedSourceId).toBeNull();
    expect(result.disciplines[0].stages.map((stage) => stage.name)).toEqual(["EC", "EC "]);
    fixture[1].data[4][0] = "Meta 1";
    expect(parseImportSheets(fixture, "Synthetic.xlsx").issues.some((issue) =>
      issue.severity === "error" && issue.code === "target_match")).toBe(true);
  });

  it("suggests one date-only target match but requires confirmation", () => {
    const fixture = sheets();
    fixture[0].data[45][3] = "Different source label";
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    const meta = result.sourceMeta.find((item) => item.sourceRow === 46);
    expect(meta).toMatchObject({ matchKind: "date_suggestion", suggestedTargetRow: 4 });
    expect(result.targets[0].matchedSourceId).toBeNull();
    expect(result.issues.some((issue) => issue.code === "target_match" && issue.row === 46)).toBe(true);
  });

  it("does not suggest a target when two unmatched Meta rows share a candidate date", () => {
    const fixture = sheets();
    fixture[0].data[45][3] = "Different source label A";
    fixture[0].data[46][3] = "Different source label B";
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    expect(result.sourceMeta.filter((item) => item.matchKind === "unresolved")).toHaveLength(2);
  });

  it("uses names for two distinct official targets that share a date", () => {
    const fixture = sheets();
    fixture[1].data[4][1] = fixture[1].data[3][1];
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    expect(result.sourceMeta.slice(0, 2).map((item) => item.matchKind)).toEqual(["exact", "exact"]);
    expect(result.targets.slice(0, 2).map((item) => item.matchedSourceId)).toEqual(["T042", "T043"]);
  });

  it("blocks date-only guesses when distinct target names share a date", () => {
    const fixture = sheets();
    fixture[1].data[4][1] = fixture[1].data[3][1];
    fixture[0].data[45][3] = "Other source label A";
    fixture[0].data[46][3] = "Other source label B";
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    expect(result.sourceMeta.slice(0, 2).map((item) => item.matchKind)).toEqual(["unresolved", "unresolved"]);
    expect(result.targets.slice(0, 2).map((item) => item.matchedSourceId)).toEqual([null, null]);
  });

  it("converts Excel serials across year boundaries in both date systems", () => {
    const fixture = sheets();
    fixture[0].data[4][4] = 46387;
    fixture[0].data[4][5] = 46388;
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    const item = result.disciplines[0].stages[0].activities[0];
    expect(item.plannedStart).toBe("2026-12-31");
    expect(item.plannedEnd).toBe("2027-01-01");
    fixture[0].data[4][4] = 0;
    fixture[0].data[4][5] = 1;
    expect(parseImportSheets(fixture, "Synthetic.xlsx", true).disciplines[0].stages[0].activities[0]
      .plannedStart).toBe("1904-01-01");
  });

  it("flags potentially executable text without executing or removing it", () => {
    const fixture = sheets();
    fixture[0].data[4][3] = "  =HYPERLINK(\"x\")";
    const result = parseImportSheets(fixture, "Synthetic.xlsx");
    expect(result.issues.some((issue) => issue.code === "untrusted_text")).toBe(true);
    expect(result.disciplines[0].stages[0].activities[0].name).toContain("=HYPERLINK");
  });

  it("ignores Gantt-only cells beyond the source rows but rejects an extra source record", () => {
    const fixture = sheets();
    const presentationOnly = Array<null | string>(13).fill(null);
    presentationOnly[12] = "=GANTT()";
    fixture[0].data.push(presentationOnly);
    expect(parseImportSheets(fixture, "Synthetic.xlsx").issues.some((issue) => issue.code === "row_limit")).toBe(false);
    fixture[0].data[50][0] = "T047";
    expect(parseImportSheets(fixture, "Synthetic.xlsx").issues.some((issue) => issue.code === "row_limit")).toBe(true);
  });
});

describe("XLSX archive preflight", () => {
  it("reads the 1904 date-system flag and rejects oversized expanded entries", () => {
    const archive = zipSync({ "xl/workbook.xml": strToU8('<workbook><workbookPr date1904="1"/></workbook>') });
    expect(validateXlsxArchive(archive)).toBe(true);
    const oversized = zipSync({ "xl/workbook.xml": strToU8("a".repeat(9 * 1024 * 1024)) });
    expect(() => validateXlsxArchive(oversized)).toThrow(ImportFileError);
  });

  it("rejects non-ZIP content", () => {
    expect(() => validateXlsxArchive(strToU8("not a workbook"))).toThrow(ImportFileError);
  });
});

it("reads a synthetic XLSX through the browser adapter without a server request", async () => {
  const cell = (column: string, row: number, value: string, numeric = false) =>
    `<c r="${column}${row}"${numeric ? "" : ' t="inlineStr"'}>${numeric ? `<v>${value}</v>` : `<is><t>${value}</t></is>`}</c>`;
  const sourceHeader = headers.map((value, index) => cell(String.fromCharCode(65 + index), 4, value)).join("");
  const sourceRow = [cell("A", 5, "T001"), cell("B", 5, "Disciplina"), cell("C", 5, "EC"),
    cell("D", 5, "Atividade R01"), cell("E", 5, "46387", true), cell("F", 5, "46388", true)].join("");
  const worksheet = (rows: string) => `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${rows}</sheetData></worksheet>`;
  const archive = zipSync({
    "[Content_Types].xml": strToU8('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'),
    "_rels/.rels": strToU8('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'),
    "xl/workbook.xml": strToU8('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Cronograma Produto" sheetId="1" r:id="rId1"/><sheet name="Metas e Premissas" sheetId="2" r:id="rId2"/></sheets></workbook>'),
    "xl/_rels/workbook.xml.rels": strToU8('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>'),
    "xl/worksheets/sheet1.xml": strToU8(worksheet(`<row r="4">${sourceHeader}</row><row r="5">${sourceRow}</row>`)),
    "xl/worksheets/sheet2.xml": strToU8(worksheet(`<row r="3">${cell("A", 3, "Meta")}${cell("B", 3, "Data")}</row><row r="4">${cell("A", 4, "Meta teste")}${cell("B", 4, "46388", true)}</row>`))
  });
  const file = new File([archive], "Synthetic.xlsx");
  if (!file.arrayBuffer) file.arrayBuffer = () => Promise.resolve(archive.buffer.slice(0) as ArrayBuffer);
  const result = await parseWorkbookFile(file);
  expect(result.disciplines[0].stages[0].activities[0]).toMatchObject({
    sourceId: "T001", plannedStart: "2026-12-31", plannedEnd: "2027-01-01"
  });
});
