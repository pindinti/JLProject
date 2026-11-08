import { unzipSync } from "fflate";
import { readSheet } from "read-excel-file/browser";
import { parseImportSheets, type ImportPreview, type ImportSheet } from "../domain/import-preview";

const maxFileBytes = 2 * 1024 * 1024;
const maxExpandedBytes = 16 * 1024 * 1024;
const maxEntryBytes = 8 * 1024 * 1024;
const maxEntries = 100;

export class ImportFileError extends Error {}

export function validateXlsxArchive(bytes: Uint8Array): boolean {
  if (bytes.length < 22 || bytes.length > maxFileBytes) throw new ImportFileError("file_size");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (view.getUint32(0, true) !== 0x04034b50) throw new ImportFileError("format");
  let eocd = -1;
  for (let offset = bytes.length - 22; offset >= Math.max(0, bytes.length - 65557); offset--) {
    if (view.getUint32(offset, true) === 0x06054b50 && offset + 22 + view.getUint16(offset + 20, true) === bytes.length) {
      eocd = offset; break;
    }
  }
  if (eocd < 0) throw new ImportFileError("format");
  const entries = view.getUint16(eocd + 10, true);
  const centralSize = view.getUint32(eocd + 12, true);
  const centralOffset = view.getUint32(eocd + 16, true);
  if (entries < 1 || entries > maxEntries || entries !== view.getUint16(eocd + 8, true) ||
      centralSize === 0xffffffff || centralOffset === 0xffffffff ||
      centralOffset + centralSize !== eocd) throw new ImportFileError("format");
  let offset = centralOffset;
  let expanded = 0;
  for (let index = 0; index < entries; index++) {
    if (offset + 46 > eocd || view.getUint32(offset, true) !== 0x02014b50) throw new ImportFileError("format");
    const flags = view.getUint16(offset + 8, true);
    const method = view.getUint16(offset + 10, true);
    const compressed = view.getUint32(offset + 20, true);
    const uncompressed = view.getUint32(offset + 24, true);
    const nameLength = view.getUint16(offset + 28, true);
    const extraLength = view.getUint16(offset + 30, true);
    const commentLength = view.getUint16(offset + 32, true);
    if ((flags & 1) !== 0 || (method !== 0 && method !== 8) || compressed === 0xffffffff ||
      uncompressed === 0xffffffff || uncompressed > maxEntryBytes) throw new ImportFileError("format");
    expanded += uncompressed;
    if (expanded > maxExpandedBytes) throw new ImportFileError("file_size");
    offset += 46 + nameLength + extraLength + commentLength;
  }
  if (offset !== eocd) throw new ImportFileError("format");
  const workbook = unzipSync(bytes, { filter: (file) => file.name === "xl/workbook.xml" })["xl/workbook.xml"];
  if (!workbook) throw new ImportFileError("format");
  const xml = new TextDecoder().decode(workbook);
  return /<\w*:?(?:workbookPr)\b[^>]*\bdate1904="(?:1|true)"/.test(xml);
}

export async function parseWorkbookFile(file: File): Promise<ImportPreview> {
  if (!/\.xlsx$/i.test(file.name)) throw new ImportFileError("format");
  if (file.size > maxFileBytes || file.size === 0) throw new ImportFileError("file_size");
  const buffer = await file.arrayBuffer();
  const date1904 = validateXlsxArchive(new Uint8Array(buffer));
  try {
    const [source, targets] = await Promise.all([
      readSheet(buffer.slice(0), "Cronograma Produto"),
      readSheet(buffer.slice(0), "Metas e Premissas")
    ]);
    return parseImportSheets([
      { sheet: "Cronograma Produto", data: source as unknown as ImportSheet["data"] },
      { sheet: "Metas e Premissas", data: targets as unknown as ImportSheet["data"] }
    ], file.name, date1904);
  } catch {
    throw new ImportFileError("format");
  }
}
