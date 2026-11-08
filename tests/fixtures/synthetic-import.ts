import { colorForLabel, type ImportSubmission } from "../../domain/import-contract";

const id = (number: number) => `T${String(number).padStart(3, "0")}`;

export function syntheticImportSubmission(): ImportSubmission {
  let activityNumber = 0;
  const disciplines = Array.from({ length: 7 }, (_, disciplineIndex) => {
    const name = `Synthetic discipline ${disciplineIndex + 1}`;
    return { name, shortCode: `D${disciplineIndex + 1}`, color: colorForLabel(name),
      displayOrder: disciplineIndex,
      stages: Array.from({ length: 3 }, (_, stageIndex) => {
        const code = `E${stageIndex + 1}`;
        const count = disciplineIndex === 6 && stageIndex === 2 ? 1 : 2;
        return { code, color: colorForLabel(code), displayName: code, displayOrder: stageIndex,
          activities: Array.from({ length: count }, () => {
            activityNumber++;
            return { sourceId: id(activityNumber), sourceRow: activityNumber + 4,
              name: `Synthetic activity R01 ${activityNumber}`, activityType: "Análise",
              status: null, notes: null, plannedStart: "2026-11-01", plannedEnd: "2026-11-03",
              displayOrder: activityNumber + 4 };
          }) };
      }) };
  });
  const dates = ["2027-01-03", "2027-02-04", "2027-03-05", "2027-04-06", "2027-05-07"];
  const sourceMeta = dates.map((date, index) => ({ sourceId: id(index + 42), sourceRow: index + 46,
    name: index < 2 ? `Synthetic target ${index + 1}` : `Alternate source label ${index + 1}`,
    discipline: "Synthetic discipline 1", stage: "E1", plannedStart: date,
    plannedEnd: date, status: null, notes: null }));
  const targets = dates.map((date, index) => ({ name: `Synthetic target ${index + 1}`,
    sourceRow: index + 4, targetDate: date,
    operationalDate: index === 0 ? "2027-01-01" : null,
    status: null, notes: null, displayOrder: index,
    matchedSourceId: id(index + 42), matchMethod: index < 2 ? "exact" as const : "date_confirmed" as const }));
  return { idempotencyKey: "11111111-1111-4111-8111-111111111111", productName: "Synthetic import",
    sourceFilename: "synthetic.xlsx", disciplines, sourceMeta, targets };
}
