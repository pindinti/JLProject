import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ImportPreview } from "../src/ImportPreview";
import { syntheticImportSubmission } from "./fixtures/synthetic-import";

const parser = vi.hoisted(() => ({ parse: vi.fn() }));
const auth = vi.hoisted(() => ({ fetch: vi.fn() }));
vi.mock("../src/auth", () => ({ authenticatedFetch: auth.fetch }));
vi.mock("../src/import-xlsx", () => ({
  parseWorkbookFile: parser.parse,
  ImportFileError: class ImportFileError extends Error {}
}));

const preview = {
  productSuggestion: "Teste Produto", issues: [], sourceMeta: [],
  summary: { sourceRecords: 46, activities: 41, targets: 5, disciplines: 7, dependencies: 0,
    firstDate: "2026-10-21", lastDate: "2028-01-17" },
  disciplines: [{ name: "Arquitetura", stages: [{ name: "EC", activities: [{
    sourceId: "T001", sourceRow: 5, name: "Entrega R01", type: "Análise", status: null,
    notes: null, plannedStart: "2026-10-21", plannedEnd: "2026-10-22"
  }] }] }],
  targets: [{ name: "Meta teste", sourceRow: 4, targetDate: "2027-01-17", operationalDate: null,
    status: null, notes: null, matchedSourceId: "T042" }]
};

beforeEach(() => { vi.clearAllMocks(); parser.parse.mockResolvedValue(preview); });

function completePreview() {
  const submission = syntheticImportSubmission();
  return {
    productSuggestion: submission.productName,
    summary: { sourceRecords: 46, activities: 41, targets: 5, disciplines: 7, dependencies: 0,
      firstDate: "2026-11-01", lastDate: "2027-05-07" },
    issues: submission.sourceMeta.slice(2).map((meta) => ({ severity: "warning", code: "target_match",
      sheet: "Cronograma Produto", row: meta.sourceRow })),
    disciplines: submission.disciplines.map((discipline) => ({ name: discipline.name,
      stages: discipline.stages.map((stage) => ({ name: stage.displayName,
        activities: stage.activities.map((activity) => ({ ...activity, type: activity.activityType })) })) })),
    sourceMeta: submission.sourceMeta.map((meta, index) => ({ ...meta,
      matchKind: index < 2 ? "exact" : "date_suggestion", suggestedTargetRow: index + 4 })),
    targets: submission.targets.map((target, index) => ({ ...target,
      matchedSourceId: index < 2 ? target.matchedSourceId : null }))
  };
}

describe("local import preview", () => {
  it("shows loading, counts, hierarchy, targets, dates, and predecessor notice", async () => {
    let resolve!: (value: unknown) => void;
    parser.parse.mockReturnValueOnce(new Promise((done) => { resolve = done; }));
    render(<ImportPreview workspaceId="e97c159e-3f7b-4e27-8b1e-38036bf47a3f"
      onBack={vi.fn()} onAccessLost={vi.fn()} onImported={vi.fn()} />);
    expect(screen.getByText("As predecessoras da planilha serão ignoradas.")).toBeInTheDocument();
    expect(screen.getByText(/Nenhum dado será salvo antes da confirmação/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Selecionar arquivo XLSX"), {
      target: { files: [new File(["synthetic"], "Synthetic.xlsx")] }
    });
    expect(screen.getByRole("status")).toHaveTextContent("Lendo e validando");
    resolve(preview);
    expect(await screen.findByText("Entrega R01", { exact: false })).toBeInTheDocument();
    expect(screen.getByText("21/10/2026 a 17/01/2028")).toBeInTheDocument();
    expect(screen.getByText(/Meta teste/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Confirmar importação" })).toBeDisabled();
  });

  it("shows a safe error and allows replacing a file", async () => {
    parser.parse.mockRejectedValueOnce(new Error("private workbook contents"));
    render(<ImportPreview workspaceId="e97c159e-3f7b-4e27-8b1e-38036bf47a3f"
      onBack={vi.fn()} onAccessLost={vi.fn()} onImported={vi.fn()} />);
    fireEvent.change(screen.getByLabelText("Selecionar arquivo XLSX"), {
      target: { files: [new File(["synthetic"], "Synthetic.xlsx")] }
    });
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível ler a planilha");
    expect(screen.getByRole("alert")).not.toHaveTextContent("private workbook contents");
    fireEvent.click(screen.getByRole("button", { name: "Cancelar ou escolher outro arquivo" }));
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("requires explicit date matches and confirms one structured import", async () => {
    parser.parse.mockResolvedValueOnce(completePreview());
    auth.fetch.mockResolvedValueOnce(new Response(JSON.stringify({ productId: "e3aa998a-a2c3-4376-9105-90af0d1dbfe3",
      revisionId: "36cb6f40-425d-4660-b204-8dd2a129371a", revisionLabel: "R00" }), { status: 201 }));
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    const onImported = vi.fn();
    render(<ImportPreview workspaceId="e97c159e-3f7b-4e27-8b1e-38036bf47a3f"
      onBack={vi.fn()} onAccessLost={vi.fn()} onImported={onImported} />);
    fireEvent.change(screen.getByLabelText("Selecionar arquivo XLSX"), {
      target: { files: [new File(["synthetic"], "Synthetic.xlsx")] }
    });
    const button = await screen.findByRole("button", { name: "Confirmar importação" });
    expect(button).toBeDisabled();
    const matches = screen.getAllByRole("checkbox");
    expect(matches).toHaveLength(3);
    expect(matches[0].closest("label")).toHaveTextContent("Alternate source label 3");
    expect(matches[0].closest("label")).toHaveTextContent("Synthetic target 3");
    for (const match of matches) fireEvent.click(match);
    expect(button).toBeEnabled();
    fireEvent.click(button);
    await waitFor(() => expect(auth.fetch).toHaveBeenCalledTimes(1));
    const [path, options] = auth.fetch.mock.calls[0];
    expect(path).toBe("/api/workspaces/e97c159e-3f7b-4e27-8b1e-38036bf47a3f/imports");
    expect(options.method).toBe("POST");
    expect(options.body).not.toContain("predecessor");
    expect(await screen.findByText("Importação concluída. O produto e o cronograma foram criados.")).toBeInTheDocument();
    expect(screen.getByText("Produto criado: Synthetic import")).toBeInTheDocument();
    expect(screen.getByText("Revisão inicial: R00")).toBeInTheDocument();
    expect(screen.getByText("Identificador da revisão: 36cb6f40-425d-4660-b204-8dd2a129371a")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Abrir cronograma" }));
    expect(onImported).toHaveBeenCalledWith("e3aa998a-a2c3-4376-9105-90af0d1dbfe3");
    confirmation.mockRestore();
  });

  it("keeps the parsed preview available after a failed save", async () => {
    parser.parse.mockResolvedValueOnce(completePreview());
    auth.fetch.mockResolvedValueOnce(new Response(null, { status: 503 }));
    const confirmation = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<ImportPreview workspaceId="e97c159e-3f7b-4e27-8b1e-38036bf47a3f"
      onBack={vi.fn()} onAccessLost={vi.fn()} onImported={vi.fn()} />);
    fireEvent.change(screen.getByLabelText("Selecionar arquivo XLSX"), {
      target: { files: [new File(["synthetic"], "Synthetic.xlsx")] }
    });
    const button = await screen.findByRole("button", { name: "Confirmar importação" });
    for (const match of screen.getAllByRole("checkbox")) fireEvent.click(match);
    fireEvent.click(button);
    expect(await screen.findByRole("alert")).toHaveTextContent("Não foi possível importar a planilha");
    expect(button).toBeEnabled();
    expect(screen.getByText("Synthetic target 1", { exact: false })).toBeInTheDocument();
    confirmation.mockRestore();
  });
});
