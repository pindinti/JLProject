import { useRef, useState } from "react";
import { authenticatedFetch } from "./auth";
import { buildImportSubmission } from "../domain/build-import-submission";
import { validateImportSubmission } from "../domain/import-contract";
import { formatCivilDate } from "./civil-date";
import { ImportFileError, parseWorkbookFile } from "./import-xlsx";
import { messages } from "./locales/pt-BR";
import type { ImportIssue, ImportPreview as Preview } from "../domain/import-preview";

const count = new Intl.NumberFormat("pt-BR");

function issueText(issue: ImportIssue): string {
  const description = messages.importIssues[issue.code];
  return `${issue.sheet}${issue.row ? `, ${messages.importRow} ${count.format(issue.row)}` : ""}: ${description}`;
}

export function ImportPreview({ workspaceId, onBack, onAccessLost, onImported }: {
  workspaceId: string; onBack: () => void; onAccessLost: () => void; onImported: (productId: string) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [state, setState] = useState<"idle" | "loading" | "ready" | "error">("idle");
  const [fileError, setFileError] = useState("");
  const [sourceFilename, setSourceFilename] = useState("");
  const [productName, setProductName] = useState("");
  const [idempotencyKey, setIdempotencyKey] = useState("");
  const [confirmed, setConfirmed] = useState<Set<string>>(new Set());
  const [importing, setImporting] = useState(false);
  const [importError, setImportError] = useState("");
  const [created, setCreated] = useState<{ productId: string; revisionId: string; revisionLabel: string } | null>(null);

  async function select(file?: File) {
    setPreview(null);
    setFileError("");
    setImportError("");
    setCreated(null);
    setConfirmed(new Set());
    if (!file) { setState("idle"); return; }
    setState("loading");
    try {
      const result = await parseWorkbookFile(file);
      setPreview(result);
      setSourceFilename(file.name);
      setProductName(result.productSuggestion);
      setIdempotencyKey(crypto.randomUUID());
      setState("ready");
    } catch (error) {
      setFileError(error instanceof ImportFileError && error.message === "file_size"
        ? messages.importFileSizeError : messages.importFileError);
      setState("error");
    }
  }

  function clear() {
    if (input.current) input.current.value = "";
    setPreview(null);
    setFileError("");
    setImportError("");
    setCreated(null);
    setConfirmed(new Set());
    setSourceFilename("");
    setProductName("");
    setIdempotencyKey("");
    setState("idle");
  }

  const submission = preview && buildImportSubmission(preview, productName, sourceFilename, idempotencyKey, confirmed);
  const canImport = Boolean(submission && validateImportSubmission(submission));
  const pendingMatches = preview?.sourceMeta.filter((meta) => meta.matchKind !== "exact" &&
    (meta.matchKind !== "date_suggestion" || !confirmed.has(meta.sourceId))) ?? [];
  const unresolvedMatches = pendingMatches.filter((meta) => meta.matchKind === "unresolved").length;
  const pendingProposals = pendingMatches.length - unresolvedMatches;
  const blockingIssues = preview?.issues.filter((issue) => issue.severity === "error" || issue.code === "count") ?? [];
  const invalidProductName = productName.trim().length < 1 || productName.trim().length > 200;
  const invalidFilename = sourceFilename.length > 255 || !/\.xlsx$/i.test(sourceFilename);
  const invalidSubmission = Boolean(preview && !blockingIssues.length && !pendingMatches.length &&
    !invalidProductName && !invalidFilename && !canImport);
  const visibleIssues = preview?.issues.filter((issue) => issue.code !== "target_match" ||
    issue.severity !== "warning" || issue.sheet !== "Cronograma Produto" ||
    !preview.sourceMeta.some((meta) => meta.sourceRow === issue.row &&
      (meta.matchKind === "exact" || (meta.matchKind === "date_suggestion" && confirmed.has(meta.sourceId))))) ?? [];

  function toggleConfirmation(sourceId: string) {
    setConfirmed((previous) => {
      const next = new Set(previous);
      if (next.has(sourceId)) next.delete(sourceId); else next.add(sourceId);
      return next;
    });
  }

  async function confirmImport() {
    if (!submission || !canImport || importing || created ||
      !window.confirm(messages.importFinalConfirmation(productName))) return;
    setImporting(true);
    setImportError("");
    try {
      const response = await authenticatedFetch(`/api/workspaces/${workspaceId}/imports`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(submission)
      });
      if (response.status === 401 || response.status === 403) { onAccessLost(); return; }
      if (response.status === 409) {
        const value = await response.json() as { code?: string };
        setImportError(value.code === "duplicate" ? messages.importDuplicate : messages.importConflict);
        return;
      }
      if (!response.ok) { setImportError(messages.importSaveError); return; }
      const result = await response.json() as { productId?: string; revisionId?: string; revisionLabel?: string };
      if (!result.productId || !result.revisionId || result.revisionLabel !== "R00") {
        setImportError(messages.importSaveError); return;
      }
      setCreated({ productId: result.productId, revisionId: result.revisionId,
        revisionLabel: result.revisionLabel });
    } catch { setImportError(messages.importSaveError); }
    finally { setImporting(false); }
  }

  return <section className="import-preview" aria-labelledby="import-title">
    <h2 id="import-title">{messages.importTitle}</h2>
    <p>{messages.importPreviewOnly}</p>
    <p>{messages.importPredecessorNotice}</p>
    <label htmlFor="import-file">{messages.importChooseFile}</label>
    <input ref={input} id="import-file" type="file" accept=".xlsx" onChange={(event) => void select(event.target.files?.[0])} />
    {state === "loading" && <p role="status">{messages.importLoading}</p>}
    {state === "error" && <p role="alert">{fileError}</p>}
    {preview && <>
      <h3>{messages.importSummary}</h3>
      <p>{messages.importProductSuggestion}: {preview.productSuggestion}</p>
      <dl className="import-summary">
        <dt>{messages.importSourceRecords}</dt><dd>{count.format(preview.summary.sourceRecords)}</dd>
        <dt>{messages.importActivities}</dt><dd>{count.format(preview.summary.activities)}</dd>
        <dt>{messages.importTargets}</dt><dd>{count.format(preview.summary.targets)}</dd>
        <dt>{messages.importDisciplines}</dt><dd>{count.format(preview.summary.disciplines)}</dd>
        <dt>{messages.importDependencies}</dt><dd>{count.format(preview.summary.dependencies)}</dd>
        <dt>{messages.importDateRange}</dt><dd>{messages.dateRange(formatCivilDate(preview.summary.firstDate), formatCivilDate(preview.summary.lastDate))}</dd>
      </dl>
      <h3>{messages.importValidation}</h3>
      {visibleIssues.length === 0 ? <p>{messages.importNoIssues}</p> : <ul>
        {visibleIssues.map((issue, index) => <li key={`${issue.sheet}-${issue.row}-${issue.code}-${index}`}>
          {issue.severity === "error" ? messages.importErrorLabel : messages.importWarningLabel}: {issueText(issue)}
        </li>)}
      </ul>}
      <h3>{messages.importReconciliation}</h3>
      <p role="status" aria-live="polite">{messages.importPendingMatches(pendingMatches.length)}</p>
      <ul>{preview.sourceMeta.map((meta) => {
        const candidate = preview.targets.find((target) => target.sourceRow === meta.suggestedTargetRow);
        return <li key={meta.sourceId}>
          {messages.importSourceRow(meta.sourceRow)}: {meta.matchKind === "exact"
            ? messages.importExactMatch
            : meta.matchKind === "date_suggestion" && candidate
              ? <label><input type="checkbox" checked={confirmed.has(meta.sourceId)}
                  onChange={() => toggleConfirmation(meta.sourceId)} />
                  {messages.importConfirmDateMatch(meta.name, candidate.name, formatCivilDate(candidate.targetDate))}</label>
              : messages.importUnresolvedMatch}
        </li>;
      })}</ul>
      <h3>{messages.importActivities}</h3>
      {preview.disciplines.map((discipline) => <section key={discipline.name} className="import-discipline">
        <h4>{discipline.name}</h4>
        {discipline.stages.map((stage) => <div key={stage.name} className="import-stage">
          <h5>{stage.name}</h5>
          {stage.activities.length === 0 && <p>{messages.importNoOperationalActivities}</p>}
          {stage.activities.length > 0 && <ul>{stage.activities.map((activity) => <li key={activity.sourceId}>
            {activity.sourceId} · {activity.name} · {messages.dateRange(formatCivilDate(activity.plannedStart), formatCivilDate(activity.plannedEnd))}
          </li>)}</ul>}
        </div>)}
      </section>)}
      <h3>{messages.importTargets}</h3>
      <ul>{preview.targets.map((target) => <li key={target.sourceRow}>
        {target.name} · {formatCivilDate(target.targetDate)}
        {target.operationalDate && ` · ${messages.importOperationalDate}: ${formatCivilDate(target.operationalDate)}`}
      </li>)}</ul>
      {!created && <div className="import-confirmation">
        <label htmlFor="import-product-name">{messages.importProductName}</label>
        <input id="import-product-name" maxLength={200} value={productName}
          onChange={(event) => setProductName(event.target.value)} />
        <p>{messages.importNewProductNotice}</p>
        {!canImport && <ul className="import-blockers" aria-live="polite">
          {blockingIssues.length > 0 && <li>{messages.importBlockingErrors(blockingIssues.length)}</li>}
          {pendingProposals > 0 && <li>{messages.importConfirmProposals(pendingProposals)}</li>}
          {unresolvedMatches > 0 && <li>{messages.importUnresolvedMatches(unresolvedMatches)}</li>}
          {invalidProductName && <li>{messages.importInvalidProductName}</li>}
          {invalidFilename && <li>{messages.importInvalidFilename}</li>}
          {invalidSubmission && <li>{messages.importInvalidSubmission}</li>}
        </ul>}
        <button type="button" disabled={!canImport || importing} onClick={() => void confirmImport()}>
          {importing ? messages.importSaving : messages.importConfirm}
        </button>
      </div>}
      {importError && <p role="alert">{importError}</p>}
      {created && <div role="status" className="feedback">
        <p>{messages.importSuccess}</p>
        <p>{messages.importCreatedProduct(productName)}</p>
        <p>{messages.importRevision}: {created.revisionLabel}</p>
        <p>{messages.importRevisionIdentifier}: {created.revisionId}</p>
        <button type="button" onClick={() => onImported(created.productId)}>{messages.openSchedule}</button>
      </div>}
    </>}
    <div className="secondary-actions">
      {(state !== "idle") && <button type="button" onClick={clear}>{messages.importReplaceFile}</button>}
      <button type="button" className="back-button" onClick={onBack}>{messages.backToProducts}</button>
    </div>
  </section>;
}
